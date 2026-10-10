//! Non-Windows stub so the receiver's status/probe wiring compiles (and is
//! testable) on any host. The driver, and therefore the endpoint, only exists
//! on Windows.

/// The friendly name the driver gives its capture endpoint.
pub const DEVICE_NAME: &str = "RemoteCrab Microphone";

/// Whether an rc-vmic capture endpoint is present — never, off Windows.
pub fn available() -> bool {
    false
}
