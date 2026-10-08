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
}

/// The receiver's presence port answers anything that connects: an old phone
/// "knocks" (connect, drop, no frame), while a phone that initiates a session
/// sends `IBPhoneHello` as its first frame. The first frame is the only thing
/// that distinguishes them, so the decision is a pure function of its kind and
/// the hello's target — testable without a socket.
public enum InboundHelloClassifier {

    /// - Parameters:
    ///   - kind: the first frame's kind, or `nil` when no frame arrived
    ///     (EOF / timeout).
    ///   - targetPcId: the `IBPhoneHello.targetPcId`, or `nil` when the frame
    ///     was not a decodable `phoneHello`.
    ///   - myPcId: this receiver's `IBClientHello.id`.
    public static func classify(kind: IBWire.Kind?, targetPcId: String?,
                                myPcId: String) -> InboundHelloDecision {
        guard kind == .phoneHello, let targetPcId else { return .knock }
        return targetPcId == myPcId ? .data : .foreign
    }
}
