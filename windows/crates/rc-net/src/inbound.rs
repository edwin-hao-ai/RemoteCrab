//! What an inbound connection to the presence/knock port is.
//!
//! The port answers anything that connects. An old phone "knocks" (connect,
//! drop, no frame); a phone that initiates a session sends `PhoneHello` as its
//! first frame. The first frame's kind, its target, and who (if anyone) already
//! owns the session are the whole decision, so it is a pure function testable
//! without a socket. Mirrors the Swift `InboundHelloClassifier`.

use rc_protocol::Kind;

/// The four things an inbound first frame can mean.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InboundDecision {
    /// A `phoneHello` addressed to this receiver — run the server-side handshake.
    Data,
    /// No frame, EOF, an unreadable frame, or a non-`phoneHello` kind — the
    /// legacy knock: the receiver dials the phone back.
    Knock,
    /// A `phoneHello` addressed to a **different** computer.
    Foreign,
    /// A `phoneHello` addressed to this receiver, but a live session is owned by
    /// a different phone. Answer a bare `busy` and close — never displace the
    /// live connection.
    Busy,
}

/// - `kind`: the first frame's kind, or `None` when no frame arrived.
/// - `target_pc_id`: the decoded hello's target, or `None` when the frame was
///   not a decodable `phoneHello`.
/// - `owner_phone_id`: the phone id that owns the live session, or `None` when
///   idle **or when the owner is known only by name** (the outbound path has no
///   phone id). A name-only owner is a session this receiver dialed, not a phone
///   that initiated, so a phone that dials now wins — answering `busy` there was
///   the race that made first contact intermittent.
pub fn classify_inbound(
    kind: Option<Kind>,
    target_pc_id: Option<&str>,
    my_pc_id: &str,
    owner_phone_id: Option<&str>,
    incoming_phone_id: Option<&str>,
) -> InboundDecision {
    let (Some(Kind::PhoneHello), Some(target)) = (kind, target_pc_id) else {
        return InboundDecision::Knock;
    };
    if target != my_pc_id {
        return InboundDecision::Foreign;
    }
    match owner_phone_id {
        None => InboundDecision::Data,
        Some(owner) if incoming_phone_id == Some(owner) => InboundDecision::Data,
        Some(_) => InboundDecision::Busy,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "pc-uuid";

    #[test]
    fn no_frame_is_a_knock() {
        assert_eq!(
            classify_inbound(None, None, ME, None, None),
            InboundDecision::Knock
        );
    }

    #[test]
    fn a_non_hello_frame_is_a_knock() {
        assert_eq!(
            classify_inbound(Some(Kind::SessionReply), None, ME, None, None),
            InboundDecision::Knock
        );
    }

    #[test]
    fn a_hello_for_me_with_no_owner_is_data() {
        assert_eq!(
            classify_inbound(Some(Kind::PhoneHello), Some(ME), ME, None, Some("p1")),
            InboundDecision::Data
        );
    }

    #[test]
    fn a_hello_for_another_computer_is_foreign() {
        assert_eq!(
            classify_inbound(Some(Kind::PhoneHello), Some("other-pc"), ME, None, Some("p1")),
            InboundDecision::Foreign
        );
    }

    /// A name-only owner (the outbound path recorded no phone id) must not block
    /// the phone's dial with `busy` — that was the race that made first contact
    /// intermittent.
    #[test]
    fn a_name_only_owner_yields_to_the_incoming_phone() {
        assert_eq!(
            classify_inbound(Some(Kind::PhoneHello), Some(ME), ME, None, Some("p1")),
            InboundDecision::Data
        );
    }

    #[test]
    fn the_owner_reconnecting_is_data_but_a_second_phone_is_busy() {
        assert_eq!(
            classify_inbound(Some(Kind::PhoneHello), Some(ME), ME, Some("p1"), Some("p1")),
            InboundDecision::Data
        );
        assert_eq!(
            classify_inbound(Some(Kind::PhoneHello), Some(ME), ME, Some("p1"), Some("p2")),
            InboundDecision::Busy
        );
    }
}
