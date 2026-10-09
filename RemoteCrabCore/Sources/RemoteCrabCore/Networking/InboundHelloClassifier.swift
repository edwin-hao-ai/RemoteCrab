import Foundation

/// What an inbound TCP connection to the receiver's presence/knock port is.
public enum InboundHelloDecision: Equatable, Sendable {
    /// A `phoneHello` addressed to this receiver — run the server-side handshake.
    case data
    /// No frame, EOF, an unreadable frame, or a non-`phoneHello` kind — the
    /// legacy knock: the receiver dials the phone back.
    case knock
    /// A `phoneHello` addressed to a **different** computer.
    case foreign
    /// A `phoneHello` addressed to this receiver, but a live session is owned by
    /// a different phone. Answer a bare `busy` and close — never displace the
    /// live connection.
    case busy
}

/// The phone that currently owns the live session, as far as the receiver knows
/// it. `phoneId` is present for a phone-initiated session; the outbound path
/// knows only the phone's display name.
public struct InboundSessionOwner: Equatable, Sendable {
    public let phoneId: String?
    public let name: String?

    public init(phoneId: String?, name: String?) {
        self.phoneId = phoneId
        self.name = name
    }
}

/// The receiver's presence port answers anything that connects: an old phone
/// "knocks" (connect, drop, no frame), while a phone that initiates a session
/// sends `IBPhoneHello` as its first frame. The first frame is the only thing
/// that distinguishes them, so the decision is a pure function of its kind, the
/// hello's target, and who (if anyone) already owns the session — testable
/// without a socket.
public enum InboundHelloClassifier {

    /// - Parameters:
    ///   - kind: the first frame's kind, or `nil` when no frame arrived
    ///     (EOF / timeout).
    ///   - targetPcId: the `IBPhoneHello.targetPcId`, or `nil` when the frame
    ///     was not a decodable `phoneHello`.
    ///   - myPcId: this receiver's `IBClientHello.id`.
    ///   - owner: the phone that owns the live session, or `nil` when idle.
    ///     Its mere presence is what turns an otherwise-acceptable hello into
    ///     `busy`, so an unauthenticated LAN peer cannot tear down a live phone.
    ///   - incomingPhoneId: the hello's stable id, to decide whether this is the
    ///     owner reconnecting (allowed) or a stranger.
    ///
    /// When the owner is known only by name (the outbound path has no phoneId),
    /// the incoming hello is admitted (`.data`): a session this receiver dialed
    /// is not a phone that initiated, so the phone that dials now takes the
    /// lead. Nothing is displaced until the candidate passes the grant policy.
    public static func classify(kind: IBWire.Kind?, targetPcId: String?,
                                myPcId: String,
                                owner: InboundSessionOwner? = nil,
                                incomingPhoneId: String? = nil) -> InboundHelloDecision {
        guard kind == .phoneHello, let targetPcId else { return .knock }
        guard targetPcId == myPcId else { return .foreign }
        guard let owner else { return .data }
        // A name-only owner is a session THIS receiver dialed (the outbound path
        // has no phoneId to record). It is not a phone that initiated, so a
        // phone that dials us now must win: the receiver yields instead of
        // answering `busy`. Answering busy here was the race that made a first
        // contact intermittent — the Mac's auto-dial and the phone's own dial
        // fired together and the phone's dial lost. The candidate still passes
        // the grant policy (a stranger gets the Mac-side prompt, never a silent
        // grant), and the live session is not torn down until a granted adopt.
        guard let ownerId = owner.phoneId else { return .data }
        return incomingPhoneId == ownerId ? .data : .busy
    }
}
