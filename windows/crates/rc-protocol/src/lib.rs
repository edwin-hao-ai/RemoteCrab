//! `rc-protocol` — the RemoteCrab wire protocol in Rust.
//!
//! A faithful, **compatible** port of `RemoteCrabCore/Networking`
//! (`IBWire` / `IBEvents` / `IBProtocol`) plus the pure-logic payloads from
//! `State/TextTransform.swift`. The iOS sender and Mac receiver are the
//! source of truth; this crate must decode exactly what they emit and
//! encode exactly what they expect.
//!
//! This crate is pure logic — no sockets, no GUI, no OS APIs — so it can be
//! unit-tested without any hardware.

pub mod base64_serde;
pub mod events;
pub mod protocol;
pub mod wire;

pub use events::*;
pub use protocol::{NalFrame, NalKind, ServiceType, StreamMetadata};
pub use wire::*;
