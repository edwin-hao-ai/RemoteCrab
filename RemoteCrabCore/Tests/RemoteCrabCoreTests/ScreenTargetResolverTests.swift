import XCTest
@testable import RemoteCrabCore

final class ScreenTargetResolverTests: XCTestCase {

    private func window(_ n: Int, pid: Int32 = 100, layer: Int = 0,
                        width: Double = 1200, height: Double = 800,
                        onScreen: Bool = true, alpha: Bool = true) -> ScreenWindowDescriptor {
        ScreenWindowDescriptor(windowNumber: n, pid: pid, layer: layer,
                               width: width, height: height,
                               isOnScreen: onScreen, hasAlpha: alpha)
    }

    func testPicksFrontmostEligibleWindowOfFrontmostApp() {
        // Front-to-back order: a different app's window comes first.
        let windows = [
            window(1, pid: 999),
            window(2, pid: 100),
            window(3, pid: 100),
        ]
        XCTAssertEqual(ScreenTargetResolver.resolve(frontmostPID: 100, windows: windows)?.windowNumber, 2)
    }

    func testSkipsIneligibleWindows() {
        let windows = [
            window(1, pid: 100, layer: 25),              // menu bar / overlay
            window(2, pid: 100, onScreen: false),        // occluded/off screen
            window(3, pid: 100, alpha: false),           // transparent
            window(4, pid: 100, width: 100),             // too small
            window(5, pid: 100),                         // the real one
        ]
        XCTAssertEqual(ScreenTargetResolver.resolve(frontmostPID: 100, windows: windows)?.windowNumber, 5)
    }

    func testReturnsNilWhenAppHasNoEligibleWindow() {
        let windows = [window(1, pid: 999), window(2, pid: 100, width: 50)]
        XCTAssertNil(ScreenTargetResolver.resolve(frontmostPID: 100, windows: windows))
    }

    func testKeepsPreviousWhenFrontmostAppHasNoWindow() {
        let previous = window(7, pid: 100)
        // Frontmost app (999) has only a too-small window → ineligible.
        let windows = [window(1, pid: 999, width: 50)]
        let resolved = ScreenTargetResolver.resolveKeepingPrevious(
            frontmostPID: 999, windows: windows, previous: previous)
        XCTAssertEqual(resolved?.windowNumber, 7)
    }

    func testPrefersNewTargetOverPreviousWhenAvailable() {
        let previous = window(7, pid: 100)
        let windows = [window(9, pid: 999)]
        let resolved = ScreenTargetResolver.resolveKeepingPrevious(
            frontmostPID: 999, windows: windows, previous: previous)
        XCTAssertEqual(resolved?.windowNumber, 9)
    }

    /// Finder with no open window is the desktop: return nil so the caller
    /// captures the whole display, instead of keeping a stale app window
    /// (the "切换到 Finder 投屏不更新" bug).
    func testDesktopShowsDisplayInsteadOfKeepingPrevious() {
        let previous = window(7, pid: 100)
        // Finder (pid 999) has no eligible window — only the desktop.
        let resolved = ScreenTargetResolver.resolveKeepingPrevious(
            frontmostPID: 999, desktopIsShowing: true,
            windows: [], previous: previous)
        XCTAssertNil(resolved)
    }

    /// A window-less NON-Finder app still keeps the previous window (avoid
    /// blanking the mirror) — `desktopIsShowing` is the only exemption.
    func testWindowlessNonFinderKeepsPrevious() {
        let previous = window(7, pid: 100)
        let resolved = ScreenTargetResolver.resolveKeepingPrevious(
            frontmostPID: 999, desktopIsShowing: false,
            windows: [], previous: previous)
        XCTAssertEqual(resolved?.windowNumber, 7)
    }

    /// Finder WITH a real window still resolves to that window (not the
    /// desktop).
    func testFinderWithWindowResolvesToIt() {
        let previous = window(7, pid: 100)
        let windows = [window(9, pid: 999)]
        let resolved = ScreenTargetResolver.resolveKeepingPrevious(
            frontmostPID: 999, desktopIsShowing: true,
            windows: windows, previous: previous)
        XCTAssertEqual(resolved?.windowNumber, 9)
    }
}
