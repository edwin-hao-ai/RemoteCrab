//! Non-Windows stub so the receiver's status/probe wiring compiles (and is
//! testable) on any host. The driver, and therefore the pipe, only exists on
//! Windows.

/// The driver's protocol version — never present off Windows.
pub fn probe() -> Option<u32> {
    None
}

/// Whether an rc-vmic driver is installed — never, off Windows.
pub fn available() -> bool {
    false
}
