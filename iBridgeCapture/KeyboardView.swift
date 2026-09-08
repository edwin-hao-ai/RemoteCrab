import SwiftUI
import UIKit
import iBridgeCore

/// A SwiftUI wrapper around a `UITextField` that captures the user's
/// typed text on the iPhone and ships it to the Mac.
///
/// V0.2 takes the simple route: let the user type on the system
/// keyboard, debounce by 100 ms, and ship a `.text` `KeyEvent` whenever
/// the buffer changes. The Mac's `CGEventPost` translates this to a
/// sequence of keystrokes.
///
/// A future V0.3 could replace this with a custom in-app keyboard that
/// sends `.down` / `.up` per physical key (which preserves shortcut
/// semantics like ⌘C, ⇧⌥→, etc.).
struct KeyboardView: UIViewRepresentable {
    let onEvent: (KeyEvent) -> Void
    @Binding var text: String

    func makeUIView(context: Context) -> KeyboardInputView {
        let view = KeyboardInputView()
        view.onEvent = onEvent
        view.textChanged = { [text = self.text] newText in
            DispatchQueue.main.async {
                self.text = newText
            }
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardInputView, context: Context) {
        uiView.onEvent = onEvent
        uiView.text = text
    }
}

/// Internal `UITextField` subclass that owns the cursor + system
/// keyboard and forwards text changes back to SwiftUI.
final class KeyboardInputView: UITextField {

    var onEvent: ((KeyEvent) -> Void)?
    var textChanged: ((String) -> Void)?

    private var lastSentText: String = ""
    private var debounce: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autocorrectionType = .yes
        autocapitalizationType = .sentences
        spellCheckingType = .yes
        keyboardType = .default
        returnKeyType = .send
        borderStyle = .roundedRect
        font = .systemFont(ofSize: 16)
        addTarget(self, action: #selector(editingChanged), for: .editingChanged)
    }

    @objc private func editingChanged() {
        let current = text ?? ""
        guard current != lastSentText else { return }
        let previous = lastSentText
        lastSentText = current

        // Cancel any pending debounce; we have new text.
        debounce?.cancel()

        // Append-only delta: if the new text starts with what we last
        // sent, ship only the appended characters.
        let appended: String
        if current.hasPrefix(previous) {
            appended = String(current.dropFirst(previous.count))
        } else {
            appended = current
        }

        let event = KeyEvent(
            action: .text,
            text: appended,
            timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000)
        )
        onEvent?(event)
        textChanged?(current)
    }

    /// Clear the buffer (e.g. user tapped the clear button).
    func clear() {
        text = ""
        lastSentText = ""
    }
}