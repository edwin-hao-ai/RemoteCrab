import XCTest
@testable import RemoteCrabCore

/// The ⊞ key row.
///
/// Two things are being pinned here. First, the Mac row must not change:
/// this is the whole product on a Mac, and a new key appearing next to
/// ⌘ would be a regression, not a feature. Second, ⊞ **replaces** ⌘ on
/// Windows rather than joining it — `windowsLabel` maps both `.control`
/// and `.command` to the string `"Ctrl"`, so the row already renders two
/// identically-labelled buttons and adding a fifth would make it worse.
final class MetaKeyRowTests: XCTestCase {

    func testMacRowIsUnchanged() {
        XCTAssertEqual(IBModifierBar.visibleModifiers(for: .mac),
                       [.control, .option, .command, .shift])
    }

    func testWindowsRowShowsWinInsteadOfCommand() {
        let row = IBModifierBar.visibleModifiers(for: .windows)
        XCTAssertTrue(row.contains(.meta))
        XCTAssertFalse(row.contains(.command), "⌘ would render a second 'Ctrl'")
        XCTAssertEqual(row.count, 4, "the row must not grow on Windows")
    }

    /// The bug this replaces: two keys, same visible label.
    func testWindowsLabelsAreDistinct() {
        let labels = IBModifierBar.visibleModifiers(for: .windows).map(\.windowsLabel)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "duplicate labels on Windows: \(labels)")
    }

    func testMacLabelsAreStillGlyphs() {
        for m in IBModifierBar.visibleModifiers(for: .mac) {
            XCTAssertFalse(m.windowsLabel == m.rawValue,
                           "\(m.rawValue) should read differently on Windows")
        }
    }

    /// 55 is kVK_Command, which `keymap.rs` already turns into `LWIN`.
    func testMetaKeycodeIsTheOneKeymapTranslatesToWin() {
        XCTAssertEqual(IBModifierBar.Modifier.meta.keycode, 55)
        XCTAssertEqual(IBModifierBar.Modifier.meta.rawValue, "⊞")
    }

    /// A long press must emit a real key event so the peer sees ⊞ held
    /// down (an input method panel, or ⊞ as a modifier for the next key).
    func testEveryVisibleModifierHasAKeycode() {
        for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
            for m in IBModifierBar.visibleModifiers(for: platform) {
                XCTAssertGreaterThan(m.keycode, 0, "\(m) on \(platform)")
                XCTAssertFalse(m.sfSymbol.isEmpty, "\(m) on \(platform)")
            }
        }
    }
}