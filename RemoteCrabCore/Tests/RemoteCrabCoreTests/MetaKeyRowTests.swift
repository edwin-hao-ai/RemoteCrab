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

    // MARK: - Shortcut chords

    /// The chord row is a **pair**: the keycap you read and the label
    /// VoiceOver speaks. The Windows row borrowed the Mac row's labels, so
    /// Ctrl+Z announced as "Mission Control" and Ctrl+A as "App Exposé" —
    /// right keycap, wrong action in the ear.
    func testEachWindowsChordIsAnnouncedAsWhatItDoes() {
        let macByKey = Dictionary(
            ShortcutChords.mac.map { ("\($0.keycode)|\($0.modifiers)", $0.accessibility) },
            uniquingKeysWith: { first, _ in first })

        for chord in ShortcutChords.windows {
            let key = "\(chord.keycode)|\(chord.modifiers)"
            if let macLabel = macByKey[key] {
                XCTAssertNotEqual(chord.accessibility, macLabel,
                                  "\(chord.text ?? "?") does a different thing on Windows "
                                  + "than on the Mac, but announces as \(macLabel)")
            }
        }
        // Mission Control / Exposé / Dock are macOS names with no PC
        // equivalent, so they must not appear in a Windows label.
        for chord in ShortcutChords.windows {
            for banned in ["Mission Control", "Exposé", "Dock"] {
                XCTAssertFalse(chord.accessibility.contains(banned),
                               "a Windows chord says \(banned): \(chord.accessibility)")
            }
        }
    }

    /// Every Windows chord must reach the receiver with Ctrl or Alt. The
    /// receiver collapses the ⌘ and ⌃ bits to Ctrl, so a chord carrying
    /// neither arrives as a bare keystroke.
    func testEveryWindowsChordCarriesAModifierTheReceiverHonours() {
        for chord in ShortcutChords.windows {
            // command(8) counts: it is what becomes Ctrl on Windows.
            let carries = chord.modifiers & (1 | 2 | 4 | 8 | 16)
            XCTAssertNotEqual(carries, 0,
                              "\(chord.text ?? "?") would arrive as a bare \(chord.keycode)")
        }
    }

    /// Two chords that collapse to the same keystroke are two buttons doing
    /// one thing — the same defect class as the context-sheet suites.
    func testNoTwoWindowsChordsCollapseToTheSameKeystroke() {
        var seen: Set<String> = []
        for chord in ShortcutChords.windows {
            let ctrl = chord.modifiers & 8 != 0 || chord.modifiers & 2 != 0
            let normalized = "\(chord.keycode)|ctrl:\(ctrl)"
                + "|alt:\(chord.modifiers & 4)"
                + "|meta:\(chord.modifiers & 16)"
            XCTAssertTrue(seen.insert(normalized).inserted,
                          "two Windows chords collapse to \(normalized)")
        }
    }

    /// The Mac set must not change shape — it is the product on a Mac.
    func testTheMacChordsAreUnchanged() {
        XCTAssertEqual(ShortcutChords.mac.count, 6)
        XCTAssertEqual(ShortcutChords.mac.map(\.text),
                       ["⌘⇥", "⌘`", nil, nil, "⌘H", "⌘Q"])
        XCTAssertEqual(ShortcutChords.chords(for: .mac), ShortcutChords.mac)
        XCTAssertEqual(ShortcutChords.chords(for: .windows), ShortcutChords.windows)
    }
}
