//! Path B — mirror the phone's mic into the rc-vmic driver's ring.
//!
//! Only active when the driver answers its control pipe (`rc_vmic::available`).
//! Otherwise the phone's mic still reaches Windows through **Path A** — a
//! virtual audio cable — and this module does nothing. Both can be true at
//! once; Path B is simply the better one where the driver is installed.
#![cfg(windows)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use rc_audio::SampleQueue;

/// The phone's mic is 48 kHz mono (Opus on iOS, `MicrophoneEncoder`).
const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u32 = 1;
/// Drain at most 100 ms per pass, so a burst after a stall cannot block the
/// pump for long.
const MAX_BATCH_SAMPLES: usize = 4_800;

/// Owns the pump thread; dropping it stops the thread.
pub struct MicRing {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl MicRing {
    /// Start feeding the driver ring from `tap`. `None` when the ring file
    /// cannot be created or the thread cannot start.
    pub fn start(tap: SampleQueue) -> Option<Self> {
        let writer = rc_vmic::AudioWriter::create(SAMPLE_RATE, CHANNELS).ok()?;
        let stop = Arc::new(AtomicBool::new(false));
        let stop_thread = stop.clone();
        let handle = std::thread::Builder::new()
            .name("rc-vmic-ring".into())
            .spawn(move || pump(tap, writer, stop_thread))
            .ok()?;
        Some(MicRing {
            stop,
            handle: Some(handle),
        })
    }
}

impl Drop for MicRing {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn pump(tap: SampleQueue, mut writer: rc_vmic::AudioWriter, stop: Arc<AtomicBool>) {
    let mut buf = vec![0i16; MAX_BATCH_SAMPLES];
    while !stop.load(Ordering::Relaxed) {
        let n = tap.len().min(MAX_BATCH_SAMPLES);
        if n == 0 {
            std::thread::sleep(Duration::from_millis(5));
            continue;
        }
        tap.pop_into(&mut buf[..n]);
        let mut bytes = Vec::with_capacity(n * 2);
        for s in &buf[..n] {
            bytes.extend_from_slice(&s.to_le_bytes());
        }
        let _ = writer.write(&bytes);
    }
}

/// One-line status for the startup banner and `--vmic-probe`.
pub fn status_line() -> (String, String) {
    match rc_vmic::probe() {
        Some(v) => (
            format!("虚拟麦克风驱动 v{v} 已就绪（\"RemoteCrab Microphone\"）"),
            format!("\"RemoteCrab Microphone\" is available (rc-vmic driver v{v})"),
        ),
        None => (
            "未安装虚拟麦克风驱动 —— 手机麦克风经虚拟声卡（Path A）可用".to_string(),
            "no rc-vmic driver — the phone mic is usable via a virtual audio cable (Path A)".to_string(),
        ),
    }
}
