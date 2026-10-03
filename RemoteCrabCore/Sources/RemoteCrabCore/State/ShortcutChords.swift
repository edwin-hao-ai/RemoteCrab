import Foundation

/// The app/window-switching chords in the keyboard surface's shortcut row.
///
/// Extracted as data for the same reason `ContextProfiles` is: the row is a
/// **pair** — the keycap you read and the label VoiceOver speaks — and the
/// two drifted apart. The Windows row borrowed the Mac row's accessibility
/// labels wholesale, so `Ctrl+Z` announced as "Mission Control" and `Ctrl+A`
/// as "App Exposé". The keycap text was right, which is exactly why nothing
/// caught it: only a VoiceOver user ever hears the label.
///
/// Keeping the pair together in one value means the view has no label to
/// get wrong, and a test can assert the pairing.
///
/// **Every chord must carry a modifier bit** — a chord with an empty mask
/// arrives as a bare keystroke. On Windows that means the ⌘ bit (8) or the ⌃
/// bit (2), which `keymap.rs` collapses to Ctrl, or the ⌥ bit (4) for the
/// two Alt chords (`Alt+Tab`, `Alt+F4`).
public enum ShortcutChords {

    public struct Chord: Equatable, Identifiable, Sendable {
        /// What the keycap reads, e.g. `"Ctrl+Z"`. `nil` when the cap is an
        /// SF Symbol instead of text.
        public let text: String?
        public let symbol: String?
        /// What VoiceOver says — **must name the action the key performs**.
        public let accessibility: String
        public let keycode: UInt16
        /// The **whole** modifier mask for the chord, in
        /// `TouchEvent.Modifier` bits (shift 1 / control 2 / option 4 /
        /// command 8 / meta 16). It is the full mask, not a delta — the
        /// sender ORs it with any modifiers the user has locked.
        public var modifiers: UInt8

        public var id: String { "\(keycode)|\(modifiers)|\(accessibility)" }

        public init(text: String? = nil, symbol: String? = nil,
                    accessibility: String, keycode: UInt16,
                    modifiers: UInt8 = 0) {
            self.text = text
            self.symbol = symbol
            self.accessibility = accessibility
            self.keycode = keycode
            self.modifiers = modifiers
        }
    }

    /// macOS: borrowed from WhisPrompt's window wheel and the Codex Micro
    /// macropad's "jump to app" keys, mapped onto macOS's own shortcuts.
    public static let mac: [Chord] = [
        Chord(text: "⌘⇥", accessibility: IBLocale.Switcher.chordAppSwitcher,
              keycode: 48, modifiers: 8),
        Chord(text: "⌘`", accessibility: IBLocale.Switcher.chordCycleWindows,
              keycode: 50, modifiers: 8),
        Chord(symbol: "rectangle.3.group",
              accessibility: IBLocale.Switcher.chordMissionControl,
              keycode: 126, modifiers: 2),
        Chord(symbol: "square.on.square",
              accessibility: IBLocale.Switcher.chordAppExpose,
              keycode: 125, modifiers: 2),
        Chord(text: "⌘H", accessibility: IBLocale.Switcher.chordHideApp,
              keycode: 4, modifiers: 8),
        Chord(text: "⌘Q", accessibility: IBLocale.Switcher.chordQuitApp,
              keycode: 12, modifiers: 8),
    ]

    /// Windows. Different keys entirely — see the note on Ctrl arriving from
    /// either the ⌘ or the ⌃ bit.
    public static let windows: [Chord] = [
        // Alt+Tab — cycles windows.
        Chord(text: "Alt⇥", accessibility: IBLocale.Switcher.windowsSwitchApps,
              keycode: 48, modifiers: 4),
        // Ctrl+W — close tab/window. W=13 + ⌘ bit (→ Ctrl).
        Chord(text: "Ctrl+W", accessibility: IBLocale.Switcher.windowsCloseWindow,
              keycode: 13, modifiers: 8),
        // Ctrl+Z / Ctrl+A — undo / select-all (Z=6, A=0).
        Chord(text: "Ctrl+Z", accessibility: IBLocale.Switcher.windowsUndo,
              keycode: 6, modifiers: 8),
        Chord(text: "Ctrl+A", accessibility: IBLocale.Switcher.windowsSelectAll,
              keycode: 0, modifiers: 8),
        // Alt+F4 — close the active window (F4 CGKeyCode 0x76=118).
        Chord(text: "Alt+F4", accessibility: IBLocale.Switcher.windowsCloseActive,
              keycode: 118, modifiers: 4),
        // Ctrl+Tab — next tab / window (Tab=48 + ⌘ bit).
        Chord(text: "Ctrl+⇥", accessibility: IBLocale.Switcher.windowsNextTab,
              keycode: 48, modifiers: 8),
    ]

    public static func chords(for platform: IBModifierBar.PeerPlatform) -> [Chord] {
        platform == .windows ? windows : mac
    }
}