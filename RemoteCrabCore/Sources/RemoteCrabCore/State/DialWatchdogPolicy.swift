import Foundation

/// When to stop waiting for a dial, and what to try instead.
///
/// ## Why this is a policy and not a comment
///
/// `ReceiverSession` armed its dial watchdog **only for direct-IP dials**
/// (`if phone.serviceEndpoint == nil`). A dial to a Bonjour *service endpoint*
/// got no watchdog at all — and that is the common case, because the whole
/// point of Bonjour is to hand out an endpoint instead of an address.
///
/// The gap is not theoretical. The iPhone advertises `_remotecrab._tcp` on
/// three interfaces simultaneously — measured with `dns-sd -L`: `if 17`,
/// `if 18` (AWDL peer-to-peer) alongside `if 13` (WiFi) — and the Mac resolved
/// an AWDL one. Unroutable for TCP in that state, so `NWConnection` sat in
/// `.preparing` indefinitely while the phone's listener, reachable on the very
/// same `192.168.31.0/24`, accepted nothing:
///
///     connecting to RemoteCrab — iPhone (serviceEndpoint: true)
///     connection state: preparing
///     … 75 s later, unchanged
///
/// A direct TCP probe to the phone succeeded immediately and the phone logged
/// `[hs] new connection accepted`, so this was never a network problem.
///
/// The fallback that would have saved it, `probeFallbackCandidates()`, is gated
/// on *"Bonjour empty"* — and Bonjour was not empty, it had found a phone whose
/// address was no good. **A discovery result is not a promise that the address
/// routes.** That sentence is the bug.
///
/// Pure and in Core so both questions can be asked without a network: whether
/// to abandon, and what to try next. They are separate because a stale *direct*
/// address and an unroutable *Bonjour endpoint* need different next steps.
public enum DialWatchdogPolicy {

    /// Seconds a dial may sit without becoming ready before it is abandoned.
    ///
    /// The same number the direct-IP dial already used, chosen because it is the
    /// one already measured in the field: long enough for a real connect on a
    /// busy link, short enough that a wedged dial costs one cycle instead of
    /// the system default's ~75 s. Giving the two dial kinds different budgets
    /// would make the behaviour depend on which kind of address the resolver
    /// happened to return — which is the entire problem.
    public static let budget: TimeInterval = 8

    /// What to do once a dial is abandoned.
    public enum NextStep: Equatable, Sendable {
        /// Cancel it and let the ordinary fallback loop take over. Right for a
        /// stale *direct* address: retrying it is pointless, but other candidates
        /// are already queued behind it.
        case abandonOnly
        /// Cancel it **and** try the remembered direct address. Right for a
        /// Bonjour endpoint: re-resolving produces the same unroutable answer,
        /// so the only way forward is a path that does not go through Bonjour.
        case tryDirectIP
    }

    /// Whether a dial that has not become ready should be given up on.
    ///
    /// Deliberately independent of which kind of dial it is — that is the fix.
    public static func shouldAbandon(isReady: Bool, isDirectDial: Bool,
                                     elapsed: TimeInterval) -> Bool {
        if isReady { return false }
        return elapsed >= budget
    }

    /// What to try after abandoning.
    public static func nextStep(isDirectDial: Bool) -> NextStep {
        isDirectDial ? .abandonOnly : .tryDirectIP
    }

    /// Whether there is a direct address worth falling back to.
    ///
    /// Separate from `nextStep` because "the Bonjour endpoint is unroutable" and
    /// "we have never learned the phone's address" are different situations, and
    /// the second must not spin.
    public static func fallbackIsPossible(hasKnownDirectIP: Bool) -> Bool {
        hasKnownDirectIP
    }
}