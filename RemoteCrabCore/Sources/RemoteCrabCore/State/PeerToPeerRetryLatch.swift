import Foundation

/// How many times a peer-to-peer dial may be retried over WiFi before the
/// attempt is given up on.
///
/// ## Why this is a type and not a `String?`
///
/// It was a `String?` holding the last phone id that had been retried, with a
/// comment saying it was "cleared when a different phone is dialled". **Nothing
/// cleared it.** The comment described the intent and the code did something
/// else — the shape this project has a lesson about, and one that is only
/// visible when the two are read side by side.
///
/// The behaviour it produced: the WiFi-only retry became **once per process**,
/// not once per attempt. One wedge, one retry, and from then on the watchdog
/// cancelled and gave up — so a phone whose AWDL endpoint wedged late in a
/// session never got the retry that exists for exactly that case.
///
/// The rule is per *attempt*: a normal dial clears the latch, so a fresh attempt
/// gets its own retry, while the retry itself sets it, so a retry cannot retry
/// itself forever. Both halves are needed and neither is obvious, which is why
/// they are here rather than in a comment.
public struct PeerToPeerRetryLatch: Equatable, Sendable {

    private var retriedFor: String?

    public init() {}

    /// A normal dial. Clears the latch so this attempt earns its own retry.
    public mutating func diallingNormally(_ phoneID: String) {
        retriedFor = nil
    }

    /// The WiFi-only retry is being made. Records it so it cannot repeat.
    public mutating func retryingWithoutPeerToPeer(_ phoneID: String) {
        retriedFor = phoneID
    }

    /// Whether this phone's one WiFi-only retry has already been spent.
    public func hasRetried(_ phoneID: String) -> Bool {
        retriedFor == phoneID
    }
}
