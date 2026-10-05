import XCTest
@testable import RemoteCrabCore

final class ComputerPresenceTests: XCTestCase {
    func testCarriesIdentityAndPlatform() {
        let p = ComputerPresence(id: "abc", name: "Edwin's PC", platform: "windows")
        XCTAssertEqual(p.id, "abc")
        XCTAssertEqual(p.name, "Edwin's PC")
        XCTAssertTrue(p.isWindows)
        XCTAssertFalse(ComputerPresence(id: "x", name: "Mac", platform: "macos").isWindows)
    }

    func testRoundTripsThroughCodable() throws {
        let p = ComputerPresence(id: "a", name: "Mac", platform: "macos",
                                 lastSeen: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(ComputerPresence.self, from: data), p)
    }
}
