import Foundation

/// Computes the minimal key-event sequence that transforms one
/// committed text into another — deletions as backspace key events
/// (macOS keycode 51), insertions as a single `.text` batch.
///
/// Used by the K3 keyboard surface: the system keyboard edits a
/// hidden UITextField, and every `editingChanged` turns into events
/// shipped to the Mac.
public enum TextDiff {

    /// macOS virtual keycode 51 — delete (backspace). Forward-delete
    /// is a different key (117) and isn't used here.
    public static let backspaceKeyCode: UInt16 = 51

    public static func events(from old: String, to new: String) -> [KeyEvent] {
        guard old != new else { return [] }

        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let deletedCount = oldChars.count - prefix - suffix
        let inserted = String(newChars[prefix ..< newChars.count - suffix])

        var events: [KeyEvent] = []
        for _ in 0 ..< deletedCount {
            events.append(KeyEvent(action: .down, keycode: backspaceKeyCode))
            events.append(KeyEvent(action: .up, keycode: backspaceKeyCode))
        }
        if !inserted.isEmpty {
            events.append(KeyEvent(action: .text, text: inserted))
        }
        return events
    }

    /// Tail-only variant for a source whose cursor is ALWAYS at the end of
    /// the text (voice dictation typed at the Mac's insertion point).
    ///
    /// `events(from:to:)` preserves a common suffix to minimise keystrokes,
    /// but that requires editing the MIDDLE of the text — impossible when
    /// every keystroke arrives at the cursor. This variant instead
    /// backspaces the whole changed tail, then types the new tail, so the
    /// result is always correct for a fixed end cursor.
    public static func tailEvents(from old: String, to new: String) -> [KeyEvent] {
        guard old != new else { return [] }

        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }

        var events: [KeyEvent] = []
        for _ in prefix ..< oldChars.count {
            events.append(KeyEvent(action: .down, keycode: backspaceKeyCode))
            events.append(KeyEvent(action: .up, keycode: backspaceKeyCode))
        }
        if prefix < newChars.count {
            events.append(KeyEvent(action: .text, text: String(newChars[prefix...])))
        }
        return events
    }
}
