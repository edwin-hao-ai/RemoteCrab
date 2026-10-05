import XCTest
@testable import RemoteCrabCore

/// How long a dial may sit un-ready before it is abandoned, and what happens
/// next.
///
/// ## Why this exists
///
/// `ReceiverSession` armed its 8-second dial watchdog **only for direct-IP
/// dials** (`if phone.serviceEndpoint == nil`). A dial to a Bonjour
/// *service endpoint* got no watchdog at all.
///
/// That is not a theoretical gap. The iPhone advertises `_remotecrab._tcp` on
/// three interfaces at once — measured with `dns-sd`: `if 17`, `if 18` (AWDL
/// peer-to-peer) and `if 13` (WiFi) — and the Mac resolved the AWDL one. That
/// endpoint is unroutable for TCP in that situation, so `NWConnection` sat in
/// `.preparing` and never left:
///
///     connecting to RemoteCrab — iPhone (serviceEndpoint: true)
///     connection state: preparing
///     … 75+ seconds later, unchanged; the phone had accepted nothing.
///
/// And the direct-IP fallback never ran, because `probeFallbackCandidates()` is
/// gated on *"Bonjour empty"*. Bonjour was not empty — it had found a phone
/// whose address was no good. So the receiver sat there while the phone, on the
/// same `192.168.31.0/24`, had a perfectly reachable listener: a plain TCP
/// probe to `192.168.31.148:8765` succeeded and the phone logged
/// `[hs] new connection accepted`.
///
/// This is lesson 48's shape again (a half-open dial wedging the Mac forever),
/// and it is the kind of "it connects sometimes" that gets filed as a network
/// problem.
///
/// ## The decision
///
/// Two questions, kept separate because they have different answers:
/// * **Should we abandon?** A dial that has not become ready within the budget.
///   True for every dial — the 8 s figure is not special to direct IPs.
/// * **What next?** A stale *direct* address has an obvious replacement
///   (another candidate, or the fallback loop). An unroutable *Bonjour
///   endpoint* has no retry — the resolution will keep producing the same
///   answer — so the replacement is the direct-IP path.
final class DialWatchdogPolicyTests: XCTestCase {

    // MARK: - Abandoning

    func testAnyDialThatIsNotReadyByTheBudgetIsAbandoned() {
        // The regression: a service-endpoint dial was exempt.
        XCTAssertTrue(DialWatchdogPolicy.shouldAbandon(
            isReady: false, isDirectDial: false, elapsed: DialWatchdogPolicy.budget))
    }

    func testADialThatIsReadyIsNeverAbandoned() {
        XCTAssertFalse(DialWatchdogPolicy.shouldAbandon(
            isReady: true, isDirectDial: false, elapsed: DialWatchdogPolicy.budget * 10))
    }

    func testNothingIsAbandonedBeforeTheBudget() {
        XCTAssertFalse(DialWatchdogPolicy.shouldAbandon(
            isReady: false, isDirectDial: false, elapsed: DialWatchdogPolicy.budget - 0.5))
    }

    func testBothDialKindsUseTheSameBudget() {
        // If the direct dial were allowed 8 s and the Bonjour one 75 s, the
        // behaviour would depend on which kind of address the resolver happened
        // to hand back — which is the whole problem.
        XCTAssertEqual(DialWatchdogPolicy.budget, 8,
                       "the existing direct-dial budget is the number that was already measured in the field")
    }

    // MARK: - What happens next

    /// The case this policy exists for: Bonjour gave us an endpoint that does
    /// not route, so cancelling is not enough — try the address we can reach.
    func testAnUnroutableBonjourEndpointFallsBackToTheDirectPath() {
        XCTAssertEqual(
            DialWatchdogPolicy.nextStep(isDirectDial: false),
            .tryDirectIP,
            "re-resolving the same endpoint will produce the same unroutable answer")
    }

    /// A stale direct address must NOT immediately retry itself, or the
    /// fallback loop never gets to try the next candidate.
    func testAStaleDirectAddressIsJustCancelled() {
        XCTAssertEqual(DialWatchdogPolicy.nextStep(isDirectDial: true), .abandonOnly)
    }

    func testTheFallbackStepIsOnlyOfferedWhenAnAddressIsActuallyKnown() {
        // No remembered address → there is nothing to fall back to, and
        // offering it would spin.
        XCTAssertFalse(DialWatchdogPolicy.fallbackIsPossible(hasKnownDirectIP: false))
        XCTAssertTrue(DialWatchdogPolicy.fallbackIsPossible(hasKnownDirectIP: true))
    }
}