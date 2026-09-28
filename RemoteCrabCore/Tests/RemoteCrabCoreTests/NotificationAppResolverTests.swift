import XCTest
@testable import RemoteCrabCore

final class NotificationAppResolverTests: XCTestCase {

    private func app(_ name: String, id: String? = nil, active: Bool = false) -> IBAppInfo {
        IBAppInfo(id: id ?? "com.example.\(name)", name: name, pid: 1, isActive: active)
    }

    func testExactNameWins() {
        let apps = [app("OpenCode"), app("OpenCode Helper")]
        XCTAssertEqual(NotificationAppResolver.resolve(name: "OpenCode", in: apps)?.name, "OpenCode")
    }

    func testCaseInsensitiveMatch() {
        let apps = [app("Terminal")]
        XCTAssertEqual(NotificationAppResolver.resolve(name: "terminal", in: apps)?.name, "Terminal")
    }

    /// A banner from a helper process must land on the app the user
    /// recognises ("Google Chrome Helper" → "Google Chrome").
    func testHelperNameResolvesToTheParentApp() {
        let apps = [app("Google Chrome")]
        XCTAssertEqual(NotificationAppResolver.resolve(name: "Google Chrome Helper", in: apps)?.name,
                       "Google Chrome")
    }

    func testPartialMatchPrefersTheActiveApp() {
        // Neither name matches exactly, so this lands in the partial tier;
        // both contain "Chrome" and the active one is the better guess.
        let apps = [app("Google Chrome"), app("Google Chrome Beta", active: true)]
        XCTAssertEqual(NotificationAppResolver.resolve(name: "Chrome", in: apps)?.name,
                       "Google Chrome Beta")
    }

    /// Exact beats "active": a running app named exactly as the banner says
    /// is the sender, even if a similarly-named app is frontmost.
    func testExactMatchBeatsTheActiveApp() {
        let apps = [app("OpenCode"), app("OpenCode Beta", active: true)]
        XCTAssertEqual(NotificationAppResolver.resolve(name: "OpenCode", in: apps)?.name, "OpenCode")
    }

    /// The quit-app case: nothing to activate, so the caller does nothing.
    func testUnknownNameResolvesToNil() {
        XCTAssertNil(NotificationAppResolver.resolve(name: "Sketch", in: [app("OpenCode")]))
    }

    func testEmptyAndWhitespaceNamesResolveToNil() {
        XCTAssertNil(NotificationAppResolver.resolve(name: "", in: [app("OpenCode")]))
        XCTAssertNil(NotificationAppResolver.resolve(name: "   ", in: [app("OpenCode")]))
    }

    func testEmptyAppListResolvesToNil() {
        XCTAssertNil(NotificationAppResolver.resolve(name: "OpenCode", in: []))
    }

    /// The notification's name is a display name that may carry the
    /// denylist-style decorations the AX description had; trimming matters.
    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(NotificationAppResolver.resolve(name: "  OpenCode  ", in: [app("OpenCode")])?.name,
                       "OpenCode")
    }
}
