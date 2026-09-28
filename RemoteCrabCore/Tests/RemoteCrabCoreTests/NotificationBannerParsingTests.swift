import XCTest
@testable import RemoteCrabCore

/// Covers the pure parsing/policy layer that used to live only inside the
/// Mac's AX polling loop (`NotificationCapture.swift`) — where a bug is
/// invisible because reproducing it needs a real banner on screen.
final class NotificationBannerParsingTests: XCTestCase {

    // MARK: - Element classification

    func testSubroleMarksABanner() {
        XCTAssertTrue(NotificationBannerParsing.isBanner(role: "AXGroup",
                                                        subrole: "AXNotificationCenterBanner",
                                                        identifier: "ABC-123"))
    }

    func testRoleOrIdentifierMayCarryTheMarker() {
        XCTAssertTrue(NotificationBannerParsing.isBanner(role: "AXNotificationCenterBannerGroup",
                                                        subrole: nil, identifier: nil))
        XCTAssertTrue(NotificationBannerParsing.isBanner(role: nil, subrole: nil,
                                                        identifier: "AXNotificationCenterBanner"))
    }

    func testOrdinaryGroupIsNotABanner() {
        // The real shape of the non-banner nodes in the tree.
        XCTAssertFalse(NotificationBannerParsing.isBanner(role: "AXGroup", subrole: "AXHostingView",
                                                         identifier: nil))
        XCTAssertFalse(NotificationBannerParsing.isBanner(role: "AXWindow", subrole: "AXUnknown",
                                                         identifier: nil))
    }

    func testSystemDialogMarker() {
        XCTAssertTrue(NotificationBannerParsing.isSystemDialog(role: "AXWindow", subrole: "AXSystemDialog"))
        XCTAssertTrue(NotificationBannerParsing.isSystemDialog(role: "AXSystemDialog", subrole: nil))
        XCTAssertFalse(NotificationBannerParsing.isSystemDialog(role: "AXWindow", subrole: "AXUnknown"))
        XCTAssertFalse(NotificationBannerParsing.isSystemDialog(role: nil, subrole: nil))
    }

    // MARK: - Scan plan (the dead-fallback regression)

    func testDialogMarkedWindowsWin() {
        XCTAssertEqual(NotificationBannerParsing.scanPlan(dialogMarkedWindows: 1,
                                                         bannerMarkedWindows: 0,
                                                         totalWindows: 4),
                       .dialogWindows)
    }

    /// Regression: banners were only sought outside a dialog-marked window
    /// when `totalWindows == 0`. Desktop widgets belong to
    /// `com.apple.notificationcenterui` on macOS 14+, so there are always
    /// windows and that branch could never run — a banner outside a dialog
    /// window was missed forever. The banner marker must now select
    /// `.allWindows` even when other windows exist.
    func testBannerMarkerSelectsAllWindowsWithWidgetsPresent() {
        XCTAssertEqual(NotificationBannerParsing.scanPlan(dialogMarkedWindows: 0,
                                                         bannerMarkedWindows: 1,
                                                         totalWindows: 4),
                       .allWindows)
    }

    func testWidgetsAloneMeanNothingOnScreen() {
        // Four windows (panel + desktop widgets), none dialog/banner marked.
        XCTAssertEqual(NotificationBannerParsing.scanPlan(dialogMarkedWindows: 0,
                                                         bannerMarkedWindows: 0,
                                                         totalWindows: 4),
                       .none)
    }

    func testNoWindowsAtAllFallsBackToAppChildren() {
        XCTAssertEqual(NotificationBannerParsing.scanPlan(dialogMarkedWindows: 0,
                                                         bannerMarkedWindows: 0,
                                                         totalWindows: 0),
                       .appChildren)
    }

    // MARK: - Identity

    func testBannerIDPrefersTheAXIdentifier() {
        XCTAssertEqual(NotificationBannerParsing.bannerID(axIdentifier: "UUID-1", contentKey: "k"), "UUID-1")
    }

    /// Regression: a banner with no `AXIdentifier` used to be dropped
    /// outright, even though the code already treats the UUID as unstable.
    func testBannerIDFallsBackToTheContentKey() {
        XCTAssertEqual(NotificationBannerParsing.bannerID(axIdentifier: nil, contentKey: "k"), "content:k")
        XCTAssertEqual(NotificationBannerParsing.bannerID(axIdentifier: "", contentKey: "k"), "content:k")
    }

    func testContentKeyDistinguishesFields() {
        let a = NotificationBannerParsing.contentKey(app: "Mail", title: "T", subtitle: "", body: "B")
        let b = NotificationBannerParsing.contentKey(app: "Mail", title: "T", subtitle: "S", body: "B")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, NotificationBannerParsing.contentKey(app: "Mail", title: "T", subtitle: "", body: "B"))
    }

    // MARK: - Source app name

    func testAppNameIsTheDescriptionPrefix() {
        let name = NotificationBannerParsing.appName(
            axDescription: "Mail You've got mail, from Bob",
            title: "You've got mail", subtitle: "", body: "from Bob")
        XCTAssertEqual(name, "Mail")
    }

    func testAppNameHandlesChineseSeparators() {
        let name = NotificationBannerParsing.appName(
            axDescription: "信息 新消息，张三",
            title: "新消息", subtitle: "", body: "张三")
        XCTAssertEqual(name, "信息")
    }

    /// Regression: when the title is a prefix of (or equal to) the app name,
    /// the cut lands at index 0 and the name came out empty — which made
    /// `parseBanner` drop the whole notification silently.
    func testAppNameNeverReturnsEmptyWhenTheTitlePrefixesTheApp() {
        let name = NotificationBannerParsing.appName(
            axDescription: "Messages Message", title: "Message", subtitle: "", body: "")
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.contains("Messages"))
    }

    func testAppNameFallsBackToTextBeforeTheFirstComma() {
        let name = NotificationBannerParsing.appName(
            axDescription: "Odd App, Title Here", title: "Title Here", subtitle: "", body: "")
        XCTAssertEqual(name, "Odd App")
    }

    func testAppNameIsEmptyForAnEmptyDescription() {
        XCTAssertEqual(NotificationBannerParsing.appName(axDescription: "", title: "T",
                                                        subtitle: "", body: ""), "")
    }

    /// The empty-name case must fail the denylist CLOSED, not open.
    func testUnparseableNameStillDeniesViaTheDescription() {
        let filter = NotificationFilter(denylist: ["Messages"])
        let description = "Messages Message"
        let name = NotificationBannerParsing.appName(axDescription: description,
                                                    title: "Message", subtitle: "", body: "")
        // The name itself may be mangled, but the description still matches.
        XCTAssertFalse(filter.shouldRelay(app: name, description: description))
    }

    func testCleanBannerIsAllowedByBothChecks() {
        let filter = NotificationFilter(denylist: ["Messages", "微信"])
        XCTAssertTrue(filter.shouldRelay(app: "Calendar", description: "Calendar Standup at 10:00"))
    }

    // MARK: - Text presence

    func testHasAnyText() {
        XCTAssertFalse(NotificationBannerParsing.hasAnyText(title: "", subtitle: "", body: ""))
        XCTAssertTrue(NotificationBannerParsing.hasAnyText(title: "T", subtitle: "", body: ""))
        XCTAssertTrue(NotificationBannerParsing.hasAnyText(title: "", subtitle: "", body: "B"))
    }
}
