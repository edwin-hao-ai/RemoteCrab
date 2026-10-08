import XCTest
@testable import RemoteCrabCore

/// The retired `current`-computer gate.
///
/// `PairingPolicy.decide` used to refuse every computer that was not the
/// persisted `current` one — the root cause of "这台能连那台不能连". That
/// gate is gone: `current` is still *stored* (`MacPairingStore.current`), but
/// the policy no longer reads it, so it can never lock a computer out again.
/// Switching is handled by the transient outbound/owner state instead.
///
/// These tests pin the retirement so the gate cannot silently return.
final class CurrentComputerPolicyTests: XCTestCase {

    private func mac(_ id: String, token: String = "t") -> PairedMac {
        PairedMac(id: id, name: id, token: token)
    }
    private func hello(_ id: String, token: String? = "t") -> IBClientHello {
        IBClientHello(name: id, id: id, token: token)
    }
    private func freshStore() -> MacPairingStore {
        let suite = "test.remotecrab.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MacPairingStore(defaults: defaults)
    }

    func testTheCurrentComputerIsAccepted() {
        let store = freshStore()
        store.setCurrent(id: "A", name: "A")
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")], owner: nil)
        XCTAssertEqual(d, .accept)
    }

    /// The invariant that replaced "current locks everyone out": a paired
    /// computer with a valid token is accepted even while `current` names a
    /// DIFFERENT computer. Built on a real store so the persisted `current`
    /// value is genuinely set, not merely absent.
    func testCurrentNoLongerLocksEveryoneOut() {
        let store = freshStore()
        store.pair(IBClientHello(name: "A", id: "A"))
        store.pair(IBClientHello(name: "B", id: "B"))
        store.setCurrent(id: "A", name: "A")
        let b = store.paired.first { $0.id == "B" }!

        let d = PairingPolicy.decide(hello: hello("B", token: b.token), paired: store.paired, owner: nil)
        XCTAssertEqual(d, .accept, "the persisted current computer must not refuse another paired one")
    }

    /// A stranger while `current` names someone else used to be answered
    /// `busy`. It is now the ordinary TOFU prompt (`pending`) — the same as
    /// with no `current` at all.
    func testAStrangerIsNoLongerRefusedByCurrent() {
        let store = freshStore()
        store.setCurrent(id: "A", name: "A")
        let d = PairingPolicy.decide(hello: hello("C", token: nil), paired: [mac("A")], owner: nil)
        XCTAssertEqual(d, .pending)
    }

    func testThePreferredComputerIsAccepted() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("A"), mac("B")],
                                     owner: nil, preferred: mac("B"))
        XCTAssertEqual(d, .accept)
    }

    func testWithoutACurrentComputerAPairedComputerIsStillAccepted() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("B")], owner: nil)
        XCTAssertEqual(d, .accept)
    }

    /// Disconnect is decided before any door — including for the `current`
    /// computer. Removing the `current` gate must not weaken this.
    func testDisconnectedStillBeatsEverything() {
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")],
                                     owner: nil, disconnected: mac("A"))
        XCTAssertEqual(d, .off(ownerName: "A"))
    }
}
