import Foundation

/// The four outcomes of the phone's half of the identity exchange, as seen by
/// the receiver. Three are not failures and only one is an attack, so they
/// cannot share a `bool`.
public enum InboundChallengeOutcome: Equatable, Sendable {
    /// The phone did not offer a proof (an older app) — unauthenticated.
    case notOffered
    /// The phone offered a proof and this receiver has no token to check it.
    case noKey
    /// The phone proved it holds the token; the receiver answered with its own.
    case proven
    /// Someone answered on the phone's port who does not hold the token.
    case failed
}

/// What the receiver should do with an inbound (phone-initiated) session once
/// the phone's `sessionReply` has been read.
public enum InboundGrantDecision: Equatable, Sendable {
    /// Admit the phone and start the session.
    case grant
    /// The phone is not paired yet — hold the connection and ask the receiver's
    /// user to confirm first contact.
    case promptFirstContact
    /// Refuse and close. A paired phone that cannot prove it holds the token is
    /// not this receiver's phone, whatever it claims.
    case refuse
}

/// The receiver-side admission rule for a **phone-initiated** connection.
///
/// The outbound (receiver-dials-phone) path is untouched: only this call site
/// gates the inbound path, because only there does an unauthenticated LAN peer
/// know the advertised id and can open the socket itself. The rule is pure so
/// the security decision is machine-verified where the socket wiring is not.
///
/// - A paired phone proves identity with the token challenge-response. A bare
///   `accepted` (or an `accepted` with no proof at all) from a paired phone is
///   refused: only new-build phones dial inbound, so a paired inbound phone is
///   expected to do peer-auth.
/// - An unpaired phone is a first pairing. The phone's `accepted{token}` alone
///   is not enough — the receiver's own user must confirm first contact, and
///   until then the connection is held without a grant.
public enum InboundGrantPolicy {
    public static func decide(paired: Bool,
                              challenge: InboundChallengeOutcome,
                              firstContactApproved: Bool) -> InboundGrantDecision {
        if challenge == .failed { return .refuse }
        if paired {
            return challenge == .proven ? .grant : .refuse
        }
        return firstContactApproved ? .grant : .promptFirstContact
    }
}
