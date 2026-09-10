import Foundation

/// Computes the minimal key-event sequence that transforms one
/// committed text into another — deletions as backspace key events
/// (macOS keycode 51), insertions as a single `.text` batch.
///
/// Used by the K3 keyboard surface: the system keyboard edits a
/// hidden UITextField, and every `editingChanged` turns into events
/// shipped to the Mac.
public enum TextDiff {

    /// macOS virtual keycode for forward-delete (backspace).
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
}
