import XCTest
@testable import RemoteCrabCore

final class IBServiceTypeTests: XCTestCase {
    func testPresenceServiceIsDistinctFromThePhoneService() {
        XCTAssertEqual(IBServiceType.computer, "_remotecrab-computer._tcp")
        XCTAssertNotEqual(IBServiceType.computer, IBServiceType.tcp)
    }

    func testTXTKeysAreFrozen() {
        XCTAssertEqual(IBServiceType.PresenceTXT.id, "id")
        XCTAssertEqual(IBServiceType.PresenceTXT.name, "name")
        XCTAssertEqual(IBServiceType.PresenceTXT.platform, "platform")
    }
}
