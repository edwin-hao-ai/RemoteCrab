import XCTest
@testable import RemoteCrabCore

final class NotificationWindowMatchTests: XCTestCase {

    func testFrontWindowTitlePicksTheFirstLayerZeroWindow() {
        // CGWindowList is front-to-back: the first entry is the frontmost.
        let windows = [
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "agent — session 3"),
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "agent — session 2"),
        ]
        XCTAssertEqual(NotificationWindowMatch.frontWindowTitle(ownerName: "OpenCode", in: windows),
                       "agent — session 3")
    }

    func testOwnerMatchIgnoresCaseAndSurroundingSpace() {
        let windows = [NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "W")]
        XCTAssertEqual(NotificationWindowMatch.frontWindowTitle(ownerName: " opencode ", in: windows), "W")
    }

    /// Only the frontmost window is considered. If it has no title, returning
    /// a *later* window's title would raise the wrong window.
    func testTitlelessFrontWindowYieldsNilRatherThanALaterWindow() {
        let windows = [
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: nil),
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "second window"),
        ]
        XCTAssertNil(NotificationWindowMatch.frontWindowTitle(ownerName: "OpenCode", in: windows))
    }

    func testEmptyTitleIsTreatedAsNoTitle() {
        let windows = [NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "")]
        XCTAssertNil(NotificationWindowMatch.frontWindowTitle(ownerName: "OpenCode", in: windows))
    }

    /// Panels/menus live above layer 0 and must not be mistaken for the
    /// app's main window.
    func testNonZeroLayerWindowsAreIgnored() {
        let windows = [
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, layer: 25, title: "menu"),
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, layer: 0, title: "main"),
        ]
        XCTAssertEqual(NotificationWindowMatch.frontWindowTitle(ownerName: "OpenCode", in: windows), "main")
    }

    func testOtherOwnersAreIgnored() {
        let windows = [
            NotificationWindowInfo(ownerName: "Finder", pid: 9, title: "Desktop"),
            NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "agent"),
        ]
        XCTAssertEqual(NotificationWindowMatch.frontWindowTitle(ownerName: "OpenCode", in: windows), "agent")
    }

    func testNoMatchingWindowYieldsNil() {
        XCTAssertNil(NotificationWindowMatch.frontWindowTitle(ownerName: "Sketch", in: []))
    }

    func testEmptyOwnerNameYieldsNil() {
        let windows = [NotificationWindowInfo(ownerName: "OpenCode", pid: 7, title: "W")]
        XCTAssertNil(NotificationWindowMatch.frontWindowTitle(ownerName: "  ", in: windows))
    }
}
