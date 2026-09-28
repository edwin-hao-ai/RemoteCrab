import XCTest
@testable import RemoteCrabCore

final class DirectDialAddressTests: XCTestCase {

    func testAcceptsNormalLANAddresses() {
        for ip in ["192.168.1.5", "10.0.0.7", "172.20.10.1", "192.168.31.26", "100.64.1.2"] {
            XCTAssertTrue(DirectDialAddress.isUsable(ip), ip)
        }
    }

    /// The regression: a simulator connecting over loopback got persisted as
    /// "the last phone IP", so the fallback dialled 127.0.0.1 forever and
    /// attached to a phantom.
    func testRejectsLoopback() {
        for ip in ["127.0.0.1", "127.1.2.3", "127.255.255.255"] {
            XCTAssertFalse(DirectDialAddress.isUsable(ip), ip)
        }
    }

    func testRejectsLinkLocal() {
        XCTAssertFalse(DirectDialAddress.isUsable("169.254.228.39"))
        XCTAssertFalse(DirectDialAddress.isUsable("169.254.0.1"))
    }

    func testRejectsWildcardAndBroadcast() {
        XCTAssertFalse(DirectDialAddress.isUsable("0.0.0.0"))
        XCTAssertFalse(DirectDialAddress.isUsable("255.255.255.255"))
    }

    /// `currentPath.remoteEndpoint` sometimes prints an interface-scoped
    /// form, which NWEndpoint cannot dial.
    func testRejectsScopedSuffix() {
        XCTAssertFalse(DirectDialAddress.isUsable("192.168.10.178%en0"))
        XCTAssertFalse(DirectDialAddress.isUsable("192.168.31.26%en0"))
    }

    func testRejectsGarbage() {
        for ip in ["", "   ", "not-an-ip", "192.168.1", "192.168.1.5.7", "192.168.1.256",
                   "192.168.1.-1", "::1", "fe80::1", "192.168.1.a"] {
            XCTAssertFalse(DirectDialAddress.isUsable(ip), ip)
        }
    }

    func testTrimsWhitespace() {
        XCTAssertTrue(DirectDialAddress.isUsable("  192.168.1.5  "))
    }
}
