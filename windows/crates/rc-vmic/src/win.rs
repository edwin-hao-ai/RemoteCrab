//! Windows half: the driver's control pipe (liveness only — the audio itself
//! travels through the ring). Kept separate so the grammar stays testable
//! everywhere.

use std::io::{BufRead, BufReader, Write};

use windows::core::PCWSTR;
use windows::Win32::System::Pipes::WaitNamedPipeW;

use crate::{parse_pong, PIPE_NAME};

/// NUL-terminated wide string.
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `WaitNamedPipeW` returns immediately when the name does not exist (driver not
/// installed) and waits only when it exists but every instance is busy, so a
/// small bound detects absence fast and rides out a momentary busy.
const PIPE_TIMEOUT_MS: u32 = 250;

/// One request/response exchange with the driver's control pipe.
///
/// `None` when the pipe is absent or the exchange fails. Presence is keyed on
/// the pipe, not the ring: a stale ring file from a crashed driver is
/// indistinguishable from a live one, but only a running driver answers.
fn roundtrip(request: &str) -> Option<String> {
    let name = wide(PIPE_NAME);
    if !unsafe { WaitNamedPipeW(PCWSTR(name.as_ptr()), PIPE_TIMEOUT_MS) }.as_bool() {
        return None;
    }
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(PIPE_NAME)
        .ok()?;
    file.write_all(request.as_bytes()).ok()?;
    file.write_all(b"\n").ok()?;
    file.flush().ok()?;
    let mut line = String::new();
    BufReader::new(file).read_line(&mut line).ok()?;
    let line = line.trim().to_string();
    if line.is_empty() {
        None
    } else {
        Some(line)
    }
}

/// The driver's protocol version, or `None` when it is not installed/running.
pub fn probe() -> Option<u32> {
    parse_pong(&roundtrip("PING")?)
}

/// Whether an rc-vmic driver is installed and answering.
pub fn available() -> bool {
    probe().is_some()
}
