import SwiftUI
import UIKit
import iBridgeCore

/// Keyboard mode (K3) — the real iOS system keyboard (IME / autocorrect /
/// 中文) types into a hidden UITextField; committed text is diffed into
/// `KeyEvent`s for the Mac. A shortcut bar provides esc / tab / arrows
/// and lockable ⌃⌥⌘⇧ modifiers, and a mini trackpad strip drives the
/// Mac cursor without leaving keyboard mode.
struct KeyboardScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @AppStorage("ibridge.ios.trackpadSens") private var trackpadSens: Int = 3

    /// Lockable modifier state — locked modifiers ride on every
    /// subsequent key / text / touch event.
    @State private var modifiers: Set<IBModifierBar.Modifier> = []
    /// Last text the Mac has seen (committed IME text only).
    @State private var committedText = ""
    @State private var keyboardHeight: CGFloat = 0
    @State private var keyboardHandle = SystemKeyboardInput.Handle()

    /// Modifier bitmask shared with TouchEvent: shift=1, control=2,
    /// option=4, command=8.
    private var modifierMask: UInt8 {
        var mask: UInt8 = 0
        if modifiers.contains(.shift) { mask |= 1 }
        if modifiers.contains(.control) { mask |= 2 }
        if modifiers.contains(.option) { mask |= 4 }
        if modifiers.contains(.command) { mask |= 8 }
        return mask
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.12),
                    Color(red: 0.15, green: 0.06, blue: 0.20)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { geo in
                VStack(spacing: 12) {
                    header
                    previewCard
                    miniTrackpad
                    shortcutBar
                    SystemKeyboardInput(
                        handle: keyboardHandle,
                        onTextChange: { old, new in handleTextChange(from: old, to: new) },
                        onReturn: { handleReturn() }
                    )
                    .frame(width: 1, height: 1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .padding(.bottom, keyboardHeight)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillChangeFrameNotification
                    )
                ) { note in
                    updateKeyboardHeight(note: note, safeAreaBottom: geo.safeAreaInsets.bottom)
                }
            }
        }
        .onAppear {
            // Delay so the keyboard slides up with the surface instead
            // of racing the feature-dock transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                // Bail on a fast surface switch: don't steal focus
                // for a keyboard that is no longer on screen.
                guard engine.features.activeSurface == .keyboard else { return }
                keyboardHandle.focus()
            }
        }
        .onDisappear {
            keyboardHandle.unfocus()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text("typing on Mac")
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.45))
                .ibEyebrowTracking()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.white.opacity(0.5))
                Text("ON YOUR MAC")
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.5))
                    .ibEyebrowTracking()
                Spacer()
                Text("\(committedText.count) chars")
                    .font(IBFont.monoSmall)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(committedText.isEmpty ? "Start typing…" : committedText)
                .font(IBFont.titleMedium)
                .foregroundStyle(committedText.isEmpty ? .white.opacity(0.35) : .white)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    // MARK: - Mini trackpad

    private var miniTrackpad: some View {
        TouchSurface(
            modifierMask: modifierMask,
            sensitivity: trackpadSens,
            onEvent: { engine.sendTouch($0) }
        )
        .frame(height: 96)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            .white.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            Text("mini trackpad")
                .font(IBFont.monoSmall)
                .foregroundStyle(.white.opacity(0.2))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Shortcut bar

    private var shortcutBar: some View {
        // Horizontally scrollable: 8 keys × 44pt + spacing exceeds a
        // 375pt screen, so scrolling keeps every key ≥44pt wide.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                shortcutKey(text: "esc", accessibility: "Escape key", keycode: 53)
                shortcutKey(text: "tab", accessibility: "Tab key", keycode: 48)
                modifierKey(.control)
                modifierKey(.option)
                modifierKey(.command)
                modifierKey(.shift)
                shortcutKey(symbol: "arrow.left", accessibility: "Left arrow key", keycode: 123)
                shortcutKey(symbol: "arrow.right", accessibility: "Right arrow key", keycode: 124)
            }
        }
    }

    private func shortcutKey(text: String? = nil, symbol: String? = nil, accessibility: String, keycode: UInt16) -> some View {
        Button {
            sendKeyTap(keycode)
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                } else {
                    Text(text ?? "")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 44, height: 44)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(ShortcutKeyStyle())
        .accessibilityLabel(accessibility)
    }

    private func modifierKey(_ modifier: IBModifierBar.Modifier) -> some View {
        let locked = modifiers.contains(modifier)
        return Button {
            if locked { modifiers.remove(modifier) }
            else { modifiers.insert(modifier) }
        } label: {
            Text(modifier.rawValue)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(locked ? .white : .white.opacity(0.65))
                .frame(width: 44, height: 44)
                .background {
                    if locked {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.4), radius: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            }
                    }
                }
        }
        .buttonStyle(ShortcutKeyStyle())
        .accessibilityLabel(modifierAccessibilityLabel(for: modifier))
        .accessibilityValue(locked ? "On" : "Off")
    }

    private func modifierAccessibilityLabel(for modifier: IBModifierBar.Modifier) -> String {
        switch modifier {
        case .control: return "Control key"
        case .option:  return "Option key"
        case .command: return "Command key"
        case .shift:   return "Shift key"
        }
    }

    // MARK: - Event plumbing

    private func sendKeyTap(_ keycode: UInt16) {
        engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: modifierMask))
        engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: modifierMask))
    }

    private func handleTextChange(from old: String, to new: String) {
        // Locked modifiers ride on every key/text event.
        for event in TextDiff.events(from: old, to: new) {
            engine.sendKey(KeyEvent(
                action: event.action,
                keycode: event.keycode,
                text: event.text,
                modifiers: modifierMask,
                timestampMicros: event.timestampMicros
            ))
        }
        committedText = new
    }

    private func handleReturn() {
        // Return = send/execute on the Mac (keycode 36); the hidden
        // field is cleared by SystemKeyboardTextField itself.
        engine.sendKey(KeyEvent(action: .down, keycode: 36, modifiers: modifierMask))
        engine.sendKey(KeyEvent(action: .up, keycode: 36, modifiers: modifierMask))
        committedText = ""
    }

    // MARK: - Keyboard avoidance

    private func updateKeyboardHeight(note: NotificationCenter.Publisher.Output, safeAreaBottom: CGFloat) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        // The end frame is in screen coordinates; while hiding it sits
        // fully below the screen, so the visible overlap drops to 0.
        let visible = max(0, scene.screen.bounds.maxY - endFrame.minY)
        withAnimation {
            keyboardHeight = max(0, visible - safeAreaBottom)
        }
    }
}

/// Pressed-state feedback for the shortcut bar — scales the key down
/// while the finger is on it (same idiom as `IBKeyboardKey`).
private struct ShortcutKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(IBAnimation.snappy, value: configuration.isPressed)
    }
}
