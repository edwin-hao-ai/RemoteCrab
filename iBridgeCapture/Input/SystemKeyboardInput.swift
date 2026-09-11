import SwiftUI
import UIKit
import os

/// Hidden 1×1 `UITextField` that hosts the real iOS system keyboard
/// (IME, autocorrect, 中文 composing). Every committed text change is
/// reported as `(old, new)` so the host can diff it into `KeyEvent`s.
final class SystemKeyboardTextField: UITextField, UITextFieldDelegate {

    /// (oldText, newText) — only fires for committed text, never for
    /// in-flight IME marked text.
    var onTextChange: ((String, String) -> Void)?
    var onReturn: (() -> Void)?

    private static let log = Logger(subsystem: "com.ibridge", category: "keyboard")
    private var lastCommitted = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .default
        // The remote Mac needs the literal characters — no curly quotes.
        smartQuotesType = .no
        returnKeyType = .default
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        // Purely a conduit for summoning the system keyboard — it must
        // never appear as a focusable element to VoiceOver.
        isAccessibilityElement = false
        delegate = self
        addTarget(self, action: #selector(editingChanged(_:)), for: .editingChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        becomeFirstResponder()
    }

    func unfocus() {
        resignFirstResponder()
    }

    @objc private func editingChanged(_ sender: UITextField) {
        // IME composition safety: `editingChanged` also fires for marked
        // (composing) text — e.g. half-typed pinyin. Diffing that would
        // ship uncommitted syllables to the Mac and then fight the final
        // commit, so while `markedTextRange` is non-nil we skip diffing
        // and wait; the event fires again once the composition commits.
        guard markedTextRange == nil else { return }
        let new = text ?? ""
        guard new != lastCommitted else { return }
        onTextChange?(lastCommitted, new)
        lastCommitted = new
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Product decision: Return = send/execute on the Mac (keycode 36),
        // it never inserts a newline into the remote field. Multi-line
        // input is a later iteration.
        Self.log.debug("return pressed — sending keycode 36, clearing field")
        onReturn?()
        text = ""
        lastCommitted = ""
        return false
    }
}

/// SwiftUI embedding of `SystemKeyboardTextField`.
///
/// Focus is owned explicitly through the `Handle`: the host calls
/// `handle.focus()` after the surface appears and `handle.unfocus()`
/// when it disappears.
struct SystemKeyboardInput: UIViewRepresentable {

    final class Handle {
        weak var field: SystemKeyboardTextField?

        func focus() {
            field?.focus()
        }

        func unfocus() {
            field?.unfocus()
        }
    }

    let handle: Handle
    var onTextChange: ((String, String) -> Void)?
    var onReturn: (() -> Void)?

    init(
        handle: Handle,
        onTextChange: ((String, String) -> Void)? = nil,
        onReturn: (() -> Void)? = nil
    ) {
        self.handle = handle
        self.onTextChange = onTextChange
        self.onReturn = onReturn
    }

    func makeUIView(context: Context) -> SystemKeyboardTextField {
        let field = SystemKeyboardTextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.onTextChange = onTextChange
        field.onReturn = onReturn
        handle.field = field
        return field
    }

    func updateUIView(_ uiView: SystemKeyboardTextField, context: Context) {
        uiView.onTextChange = onTextChange
        uiView.onReturn = onReturn
    }
}
