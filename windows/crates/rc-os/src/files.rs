//! File-receive bookkeeping. The wire transfers one file at a time
//! (`fileOffer` → raw `fileChunk`* → `fileComplete`), so this is a small
//! state machine with a pure, testable core.

use std::io::Write;
use std::path::{Path, PathBuf};

use rc_protocol::{FileAck, FileAckStatus, FileOffer};

/// Strip path separators and reserved characters so an iPhone-supplied name
/// can never escape the destination directory or create a bad filename.
pub fn sanitize_file_name(name: &str) -> String {
    // Keep only the final path component, then scrub Windows-reserved chars.
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name)
        .trim()
        .trim_matches('.');
    let mut out = String::with_capacity(base.len());
    for ch in base.chars() {
        match ch {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => out.push('_'),
            c if (c as u32) < 0x20 => out.push('_'),
            c => out.push(c),
        }
    }
    if out.is_empty() {
        out.push_str("received-file");
    }
    // Windows reserved device names.
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
        "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    let stem = out.split('.').next().unwrap_or("").to_ascii_uppercase();
    if RESERVED.contains(&stem.as_str()) {
        out = format!("_{out}");
    }
    out
}

/// Pick a non-colliding path in `dir` for `name` (`report` → `report (1)`).
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let sanitized = sanitize_file_name(name);
    let candidate = dir.join(&sanitized);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(&sanitized);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = path.extension().and_then(|s| s.to_str());
    for n in 1..10_000 {
        let alt = match ext {
            Some(e) => format!("{stem} ({n}).{e}"),
            None => format!("{stem} ({n})"),
        };
        let candidate = dir.join(alt);
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem}-{}", std::process::id()))
}

/// Receives one file at a time from the iPhone.
pub struct FileReceiver {
    dir: PathBuf,
    active: Option<ActiveFile>,
}

struct ActiveFile {
    offer: FileOffer,
    path: PathBuf,
    file: std::fs::File,
    received: i64,
}

impl FileReceiver {
    pub fn new(dir: PathBuf) -> Self {
        FileReceiver { dir, active: None }
    }

    /// Begin a transfer. Returns the ack to send back.
    pub fn begin(&mut self, offer: FileOffer) -> FileAck {
        if std::fs::create_dir_all(&self.dir).is_err() {
            return FileAck {
                id: offer.id.clone(),
                status: FileAckStatus::Error,
                received_bytes: 0,
                path: None,
            };
        }
        let path = unique_path(&self.dir, &offer.name);
        match std::fs::File::create(&path) {
            Ok(file) => {
                let ack = FileAck {
                    id: offer.id.clone(),
                    status: FileAckStatus::Progress,
                    received_bytes: 0,
                    path: None,
                };
                self.active = Some(ActiveFile {
                    offer,
                    path,
                    file,
                    received: 0,
                });
                ack
            }
            Err(_) => FileAck {
                id: offer.id.clone(),
                status: FileAckStatus::Error,
                received_bytes: 0,
                path: None,
            },
        }
    }

    /// Append a chunk. Returns None when no transfer is active.
    pub fn append(&mut self, data: &[u8]) -> Option<FileAck> {
        let active = self.active.as_mut()?;
        if active.file.write_all(data).is_err() {
            return Some(FileAck {
                id: active.offer.id.clone(),
                status: FileAckStatus::Error,
                received_bytes: active.received,
                path: None,
            });
        }
        active.received += data.len() as i64;
        Some(FileAck {
            id: active.offer.id.clone(),
            status: FileAckStatus::Progress,
            received_bytes: active.received,
            path: None,
        })
    }

    /// Finish the transfer. Returns the final ack with the saved path.
    pub fn complete(&mut self, id: &str) -> Option<(FileAck, PathBuf)> {
        let active = self.active.take()?;
        if active.offer.id != id {
            // A mismatched id means the stream got out of sync; drop it.
            return None;
        }
        drop(active.file);
        let ack = FileAck {
            id: active.offer.id.clone(),
            status: FileAckStatus::Saved,
            received_bytes: active.received,
            path: Some(active.path.to_string_lossy().to_string()),
        };
        Some((ack, active.path))
    }

    pub fn received_bytes(&self) -> i64 {
        self.active.as_ref().map(|a| a.received).unwrap_or(0)
    }
}

/// Open Explorer with `path` selected (the Windows equivalent of the Mac
/// receiver's "reveal in Finder").
#[cfg(windows)]
pub fn reveal(path: &Path) {
    let wide: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        windows::Win32::UI::Shell::ShellExecuteW(
            None,
            windows::core::w!("open"),
            windows::core::w!("explorer.exe"),
            windows::core::PCWSTR(wide.as_ptr()),
            None,
            windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL,
        );
    }
}

#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn sanitize_strips_path_traversal() {
        assert_eq!(sanitize_file_name("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_file_name("C:\\Windows\\evil.exe"), "evil.exe");
        assert_eq!(sanitize_file_name("/abs/path/photo.jpg"), "photo.jpg");
    }

    #[test]
    fn sanitize_replaces_reserved_chars() {
        assert_eq!(sanitize_file_name("a<b>c:d\"e|f?g*h"), "a_b_c_d_e_f_g_h");
    }

    #[test]
    fn sanitize_handles_empty_and_dots() {
        assert_eq!(sanitize_file_name(""), "received-file");
        assert_eq!(sanitize_file_name("..."), "received-file");
        assert_eq!(sanitize_file_name("   "), "received-file");
    }

    #[test]
    fn sanitize_neutralizes_windows_device_names() {
        assert_eq!(sanitize_file_name("CON"), "_CON");
        assert_eq!(sanitize_file_name("nul.txt"), "_nul.txt");
        assert_eq!(sanitize_file_name("COM1"), "_COM1");
    }

    #[test]
    fn unique_path_appends_a_counter() {
        let dir = std::env::temp_dir().join(format!("rc-os-uniq-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let first = unique_path(&dir, "note.txt");
        assert!(first.ends_with("note.txt"));
        std::fs::write(&first, b"x").unwrap();

        let second = unique_path(&dir, "note.txt");
        assert!(second.ends_with("note (1).txt"), "got {second:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn receiver_writes_the_file_and_acks_progress_then_saved() {
        let dir = std::env::temp_dir().join(format!("rc-os-recv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);

        let mut rx = FileReceiver::new(dir.clone());
        let offer = FileOffer {
            id: "f1".to_string(),
            name: "hello.txt".to_string(),
            size: 11,
        };
        let ack = rx.begin(offer);
        assert_eq!(ack.status, FileAckStatus::Progress);

        let ack = rx.append(b"hello ").unwrap();
        assert_eq!(ack.received_bytes, 6);
        let ack = rx.append(b"world").unwrap();
        assert_eq!(ack.received_bytes, 11);

        let (final_ack, path) = rx.complete("f1").unwrap();
        assert_eq!(final_ack.status, FileAckStatus::Saved);
        assert_eq!(final_ack.received_bytes, 11);

        let mut content = String::new();
        std::fs::File::open(&path).unwrap().read_to_string(&mut content).unwrap();
        assert_eq!(content, "hello world");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn receiver_rejects_mismatched_complete_id() {
        let dir = std::env::temp_dir().join(format!("rc-os-mismatch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut rx = FileReceiver::new(dir.clone());
        rx.begin(FileOffer {
            id: "f1".to_string(),
            name: "a.txt".to_string(),
            size: 1,
        });
        assert!(rx.complete("other").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
