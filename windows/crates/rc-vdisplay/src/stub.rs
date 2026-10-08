//! Non-Windows build: there is no IddCx indirect-display driver off Windows,
//! so the feature is always absent. Present so the receiver crate and its
//! tests build on a dev host (macOS/Linux), where `rc-app` compiles the mirror
//! controller with these stubs.

use crate::DisplayFrame;

/// No virtual-display driver exists off Windows.
pub fn probe() -> Option<u32> {
    None
}

/// Always absent off Windows.
pub fn available() -> bool {
    false
}

/// Nothing to command off Windows.
pub fn set_monitor(_size: Option<(u32, u32)>) -> Result<(), String> {
    Err("extended display is Windows-only".to_string())
}

/// No virtual monitor exists off Windows.
pub fn find_monitor_rect(_width: u32, _height: u32) -> Option<(f64, f64, f64, f64)> {
    None
}

/// Nothing to read off Windows.
pub struct DisplayReader;

impl DisplayReader {
    pub fn open() -> Option<Self> {
        None
    }

    pub fn latest(&self) -> Option<DisplayFrame> {
        None
    }
}
