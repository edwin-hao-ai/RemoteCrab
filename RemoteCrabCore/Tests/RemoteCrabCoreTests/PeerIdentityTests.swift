import XCTest
@testable import RemoteCrabCore

/// The peer's identity — who is on the other end, and what they have running.
///
/// ## Why this type exists
///
/// These four lists used to be four independent `@Published` arrays on
/// `CaptureEngine`. `clearOwner` reset eighteen other fields but none of
/// them, so **the phone never forgot the previous computer**: switch from
/// the Mac to Windows and the context sheet's header named the Mac's
/// frontmost app (on a Chinese macOS that string is literally `访达`), the
/// launcher offered the Mac's bundle ids, and the window picker offered a
/// Mac window.
///
/// The bug is not "someone forgot a line in a teardown". It is that the
/// state describing *whose computer this is* had no owner and no single
/// operation that ends it. So the state is one value with one `clear()`,
/// and the invariant lives in the type: **an identity with nothing
/// installed has no frontmost app**, which is the whole fix.
///
/// These tests assert the invariant, not the calls that maintain it. The
/// production change that would break them is removing `clear()` from the
/// ownership teardown — which is exactly the regression, so the tests fail
/// if someone "optimises" the wipe away.
final class PeerIdentityTests: XCTestCase {

    // MARK: - Fixtures

    /// The Mac's frontmost app, named the way a Chinese macOS names it.
    private func macFinder() -> IBAppInfo {
        IBAppInfo(id: "com.apple.finder", name: "访达", pid: 201, isActive: true)
    }

    private func macSafari() -> IBAppInfo {
        IBAppInfo(id: "com.apple.Safari", name: "Safari", pid: 202, isActive: false)
    }

    /// What the Windows receiver actually sends: `id` is `pid:<n>`, which
    /// changes every launch, and the name is the process stem.
    private func windowsTerminal() -> IBAppInfo {
        IBAppInfo(id: "pid:4242", name: "WindowsTerminal", pid: 4242, isActive: true)
    }

    private func macWindow(appId: String, id: String) -> IBWindowInfo {
        IBWindowInfo(id: id, appId: appId, appName: "访达", title: "Downloads",
                     isActive: false, width: 800, height: 600)
    }

    // MARK: - Empty is the default, and it answers nothing

    func testAFreshIdentityHasNoAppsAndNoFrontmostApp() {
        let peer = PeerIdentity()
        XCTAssertTrue(peer.apps.isEmpty)
        XCTAssertNil(peer.frontmostApp, "an identity with nothing installed must not name an app")
    }

    func testAnEmptyIdentityReportsItselfEmpty() {
        XCTAssertTrue(PeerIdentity().isEmpty)
    }

    /// The derived read is what the context sheet renders. This is the
    /// assertion that would have caught the reported bug at its source.
    func testFrontmostAppIsNilUntilAnAppListIsInstalled() {
        var peer = PeerIdentity()
        peer.install(apps: [])
        XCTAssertNil(peer.frontmostApp)
    }

    // MARK: - clear() ends ALL of it, in one operation

    func testClearEmptiesEveryKindOfPeerState() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder(), macSafari()])
        peer.install(windows: [macWindow(appId: "com.apple.finder", id: "w1")], canCapture: true)
        peer.install(installedApps: [IBInstalledApp(id: "com.apple.finder", name: "访达")])

        peer.clear()

        XCTAssertTrue(peer.apps.isEmpty)
        XCTAssertTrue(peer.windows.isEmpty)
        XCTAssertTrue(peer.installedApps.isEmpty)
        XCTAssertFalse(peer.windowsCanCapture,
                       "a stale `true` here puts the Mac's mirror affordance in front of a Windows user")
        XCTAssertNil(peer.frontmostApp)
        XCTAssertTrue(peer.isEmpty)
    }

    // MARK: - The reported sequence

    /// Mac → Windows. The exact report: on a Windows session the context
    /// sheet said `访达`, because the Mac's app list outlived the Mac.
    ///
    /// The shape matters and getting it wrong made this test useless. The
    /// first attempt installed the Windows list after `clear()`, which
    /// **passed even with `clear()` sabotaged** — `install` replaces, so a
    /// replacement hides a missing wipe. The real exposure is the window
    /// where the new computer has accepted the session but has not yet
    /// answered an `appListRequest`: Windows only publishes that list *on
    /// request* (`rc-app` handles `AppListRequest`, the Mac pushes
    /// proactively), and a peer that never answers it leaves the previous
    /// computer's list in place indefinitely.
    ///
    /// So: no new list arrives, and the identity must still name nobody.
    func testMacAppsDoNotSurviveTheSwitchToWindows() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder(), macSafari()])
        XCTAssertEqual(peer.frontmostApp?.id, "com.apple.finder", "precondition")

        peer.clear()                    // the Mac goes away
        peer.install(windows: [], canCapture: false)   // Windows connects…
        // …and has not answered yet. Nothing may be named.

        XCTAssertNil(peer.frontmostApp,
                     "a stale Mac app here is what the context sheet's header rendered on Windows")
        XCTAssertFalse(peer.apps.contains { $0.id == "com.apple.finder" },
                       "a Mac bundle id survived into a Windows session")
    }

    /// The suite lookup runs on that stale name, so the second half of the
    /// bug is that a Windows peer with no list of its own is matched
    /// against the *Mac's* bundle id. Model the real inputs, not the
    /// symptom: `profile(for:)` takes the id the receiver sent, and on
    /// Windows that id is `pid:<n>`, which no Mac suite claims.
    func testAWindowsPeerWithNoAnswerMatchesNoSuite() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder()])
        peer.clear()

        let app = peer.frontmostApp
        XCTAssertNil(app)
        // What the sheet would render with a stale list, for contrast:
        XCTAssertEqual(
            ContextProfiles.profile(for: macFinder(), platform: .mac).id, "finder",
            "precondition: a stale Mac list DOES select the Mac Finder suite on a mac peer"
        )
        XCTAssertEqual(
            ContextProfiles.profile(for: app, platform: .windows).id, "console",
            "with nothing installed the Windows peer gets the console fallback, not a Mac suite"
        )
    }

    /// The ordering that produced "the list showed nothing at all" is the
    /// same bug read backwards: a new computer's list must be able to
    /// replace an old one without the old one winning.
    func testAListFromTheNewPeerReplacesTheOldRatherThanAccumulating() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder()])
        peer.clear()
        peer.install(apps: [windowsTerminal()])
        XCTAssertEqual(peer.apps.count, 1, "install replaces; it does not merge")
        XCTAssertEqual(peer.apps.first?.name, "WindowsTerminal")
    }

    /// Nothing is installed and the phone reconnects to the same Mac: the
    /// answer arrives, then a stale clear must not resurrect an old name.
    func testRepeatedClearIsIdempotent() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder()])
        peer.clear()
        peer.clear()
        XCTAssertNil(peer.frontmostApp)
        XCTAssertTrue(peer.isEmpty)
    }

    // MARK: - Reads that must not invent an answer

    func testFrontmostAppIsNilWhenNoEntryIsMarkedActive() {
        var peer = PeerIdentity()
        peer.install(apps: [macSafari()])
        XCTAssertNil(peer.frontmostApp,
                     "Windows reports `is_active` per foreground pid; a list with none active is real")
    }

    func testFrontmostAppIsTheFirstActiveEntry() {
        var peer = PeerIdentity()
        peer.install(apps: [macSafari(), macFinder(), macWindowless()])
        XCTAssertEqual(peer.frontmostApp?.name, "访达")
    }

    private func macWindowless() -> IBAppInfo {
        IBAppInfo(id: "com.apple.Notes", name: "备忘录", pid: 203, isActive: true)
    }

    // MARK: - windowsCanCapture travels with the windows, not beside them

    func testWindowsCanCaptureIsFalseUntilAWindowListSaysOtherwise() {
        var peer = PeerIdentity()
        XCTAssertFalse(peer.windowsCanCapture)
        peer.install(windows: [], canCapture: false)
        XCTAssertFalse(peer.windowsCanCapture)
        peer.install(windows: [macWindow(appId: "a", id: "w")], canCapture: true)
        XCTAssertTrue(peer.windowsCanCapture)
    }

    /// An app that quit must not keep offering its windows. This is the one
    /// mutating read `CaptureEngine` performs outside install/clear.
    func testForgettingAnAppDropsOnlyThatAppsWindows() {
        var peer = PeerIdentity()
        peer.install(windows: [macWindow(appId: "com.apple.finder", id: "w1"),
                               macWindow(appId: "com.apple.Safari", id: "w2")],
                     canCapture: true)
        peer.forgetWindow(appId: "com.apple.finder")
        XCTAssertEqual(peer.windows.map(\.id), ["w2"])
    }

    func testForgettingAnAbsentAppChangesNothing() {
        var peer = PeerIdentity()
        peer.install(windows: [macWindow(appId: "com.apple.Safari", id: "w2")], canCapture: true)
        peer.forgetWindow(appId: "com.example.never.ran")
        XCTAssertEqual(peer.windows.map(\.id), ["w2"])
        XCTAssertTrue(peer.windowsCanCapture)
    }

    // MARK: - installed apps

    func testInstalledAppsSurviveOnlyUntilTheNextClear() {
        var peer = PeerIdentity()
        peer.install(installedApps: [IBInstalledApp(id: "com.apple.finder", name: "访达"),
                                     IBInstalledApp(id: "C:\\Program Files\\x.exe", name: "x")])
        XCTAssertEqual(peer.installedApps.count, 2)
        peer.clear()
        XCTAssertTrue(peer.installedApps.isEmpty,
                      "a Windows launcher that lists the Mac's bundle ids is this field surviving")
    }

    /// Installing windows/apps must not silently reset an unrelated field:
    /// the four answers arrive as separate frames and each replaces only
    /// its own.
    func testEachInstallTouchesOnlyItsOwnField() {
        var peer = PeerIdentity()
        peer.install(apps: [macFinder()])
        peer.install(windows: [macWindow(appId: "x", id: "w")], canCapture: true)
        peer.install(installedApps: [IBInstalledApp(id: "y", name: "y")])

        peer.install(apps: [windowsTerminal()])

        XCTAssertEqual(peer.apps.first?.id, "pid:4242")
        XCTAssertEqual(peer.windows.count, 1, "a new app list must not wipe the window list")
        XCTAssertEqual(peer.installedApps.count, 1)
    }
}