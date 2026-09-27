import XCTest
@testable import RemoteCrabCore

final class NotificationFilterTests: XCTestCase {
    func testAllowsUnknownApp() {
        XCTAssertTrue(NotificationFilter().shouldRelay(app: "OpenCode"))
    }
    func testBlocksDenylistedApp() {
        let f = NotificationFilter(denylist: ["Messages", "信息"])
        XCTAssertFalse(f.shouldRelay(app: "Messages"))
        XCTAssertFalse(f.shouldRelay(app: "信息"))
    }
    func testCaseInsensitive() {
        XCTAssertFalse(NotificationFilter(denylist: ["messages"]).shouldRelay(app: "Messages"))
    }
    func testEmptyDenylistAllowsAll() {
        XCTAssertTrue(NotificationFilter(denylist: []).shouldRelay(app: "Anything"))
    }
    func testDefaultDenylistCoversSensitiveApps() {
        let f = NotificationFilter()
        for app in ["Messages", "Mail", "信息", "邮件", "1Password", "WeChat", "微信"] {
            XCTAssertFalse(f.shouldRelay(app: app), app)
        }
    }
}
