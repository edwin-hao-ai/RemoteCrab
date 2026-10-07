import XCTest
@testable import RemoteCrabCore

final class CurrentComputerPolicyTests: XCTestCase {

    private func mac(_ id: String, token: String = "t") -> PairedMac {
        PairedMac(id: id, name: id, token: token)
    }
    private func hello(_ id: String, token: String? = "t") -> IBClientHello {
        IBClientHello(name: id, id: id, token: token)
    }

    func testTheCurrentComputerIsAccepted() {
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .accept)
    }

    func testANonCurrentPairedComputerStandsBy() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("A"), mac("B")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .busy(ownerName: "A"))
    }

    func testThePreferredComputerOverridesCurrent() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("A"), mac("B")],
                                     owner: nil, preferred: mac("B"), current: mac("A"))
        XCTAssertEqual(d, .accept)
    }

    func testWithoutACurrentComputerAPairedComputerIsStillAccepted() {
        let d = PairingPolicy.decide(hello: hello("B"), paired: [mac("B")],
                                     owner: nil, current: nil)
        XCTAssertEqual(d, .accept)
    }

    func testAStrangerGetsBusyWhenACurrentComputerExists() {
        let d = PairingPolicy.decide(hello: hello("C", token: nil), paired: [mac("A")],
                                     owner: nil, current: mac("A"))
        XCTAssertEqual(d, .busy(ownerName: "A"))
    }

    func testDisconnectedBeatsCurrent() {
        let d = PairingPolicy.decide(hello: hello("A"), paired: [mac("A")],
                                     owner: nil, disconnected: mac("A"), current: mac("A"))
        XCTAssertEqual(d, .off(ownerName: "A"))
    }
}
