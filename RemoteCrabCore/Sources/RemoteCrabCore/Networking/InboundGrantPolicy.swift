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
    /// Refuse and close. A phone that presented a proof which does not match a
    /// paired token is an impersonation attempt.
    case refuse
}

/// The receiver-side admission rule for a **phone-initiated** connection.
///
/// The user's own tap in the phone's picker is the consent: the phone shows the
/// one confirmation card, and its `accepted` is the decision. The receiver does
/// not add a second, hidden gate — that is the category norm (Remote Mouse, TV
/// remotes) and the reason a first connect "just works". Identity is still
/// enforced *after* pairing: a paired phone proves the token, so an impersonator
/// cannot silently take over an existing pairing, and a wrong proof is refused.
public enum InboundGrantPolicy {
    public static func decide(challenge: InboundChallengeOutcome) -> InboundGrantDecision {
        // A wrong proof is an impersonation attempt on a paired session.
        if challenge == .failed { return .refuse }
        // Everything else is the phone deciding for itself: admit it. An
        // unpaired first contact is trusted on first use (the phone's own card
        // is the consent); a stale/missing proof is re-paired by the token the
        // phone seconds later.
        return .grant
    }
}
