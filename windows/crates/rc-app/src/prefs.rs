//! Device preferences the tray toggles: the virtual camera, and whether the
//! phone's microphone plays on this PC's speakers.
//!
//! Both were command-line flags (`--vcam`, `--unmute`) — which no normal user
//! passes, because the product is launched from the tray / Start Menu. They are
//! persisted as a small JSON file under `%APPDATA%`, matching the rest of the
//! app, and **defaulted additively** so an older file (or none) loads without
//! losing anything (AGENTS.md rule 2).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Devices {
    /// Publish the phone's video to the "RemoteCrab" virtual camera. On by
    /// default: that is the whole point of the camera, and a user who installed
    /// it expects it to work without a flag.
    #[serde(default = "yes")]
    pub vcam: bool,
    /// Play the phone's microphone on this PC's speakers. Off by default: a mic
    /// on the speakers next to the phone is a feedback loop.
    #[serde(default)]
    pub pc_audio: bool,
}

fn yes() -> bool {
    true
}

impl Default for Devices {
    fn default() -> Self {
        Devices {
            vcam: true,
            pc_audio: false,
        }
    }
}

fn path() -> Option<std::path::PathBuf> {
    crate::notify_relay::app_data_dir().map(|d| d.join("devices.json"))
}

fn read() -> Devices {
    path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write(d: &Devices) -> bool {
    let Some(p) = path() else {
        return false;
    };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    serde_json::to_string_pretty(d)
        .ok()
        .and_then(|t| std::fs::write(&p, t).ok())
        .is_some()
}

/// Whether the virtual camera should run (the tray toggle, default on).
pub fn vcam() -> bool {
    read().vcam
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn set_vcam(on: bool) {
    let mut d = read();
    d.vcam = on;
    let _ = write(&d);
}

/// Whether the phone's mic should play on this PC's speakers (default off).
pub fn pc_audio() -> bool {
    read().pc_audio
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn set_pc_audio(on: bool) {
    let mut d = read();
    d.pc_audio = on;
    let _ = write(&d);
}

#[cfg(test)]
mod tests {
    use super::Devices;

    /// Rule 2, as a test: a file written before a field existed — or no file at
    /// all — must load with the defaults rather than being discarded. The
    /// defaults also encode the product decision: camera on, monitor off.
    #[test]
    fn an_older_or_empty_file_loads_with_the_defaults() {
        let d: Devices = serde_json::from_str("{}").expect("empty object");
        assert!(d.vcam, "the camera defaults on");
        assert!(!d.pc_audio, "monitoring defaults off");

        // An old file that only knew about the camera.
        let d: Devices = serde_json::from_str(r#"{"vcam":false}"#).expect("one field");
        assert!(!d.vcam);
        assert!(!d.pc_audio);

        assert!(Devices::default().vcam);
        assert!(!Devices::default().pc_audio);
    }
}
