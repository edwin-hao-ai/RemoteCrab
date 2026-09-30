//! Windows notification capture, kept in its own crate so the WinRT features
//! cannot leak into the crates that are tested on a Mac.
//!
//! See `Cargo.toml` for why. The short version: `windows`'s WinRT features pull
//! in `windows-future`, which cannot compile off Windows, and Cargo unifies
//! those features across a workspace — so enabling them in `rc-os` broke
//! `cargo test -p rc-os` on macOS. The decision logic that actually matters
//! (denylist, fail-closed on an unnamed sender, dropping empty banners) is in
//! `rc_net::notify` and is tested on every host; this crate is only the
//! Windows-shaped capture.

#[cfg(windows)]
pub mod win;

#[cfg(windows)]
pub use win::{poll_once, start, Listener, SeenSet};
