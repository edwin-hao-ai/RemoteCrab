import SwiftUI
import UIKit
import RemoteCrabCore

/// Keyboard mode (K3) — the real iOS system keyboard (IME / autocorrect /
/// 中文) types into a hidden UITextField; committed text is diffed into
/// `KeyEvent`s for the Mac. A shortcut bar provides esc / tab / arrows
/// and lockable ⌃⌥⌘⇧ modifiers, and a mini trackpad strip drives the
/// Mac cursor without leaving keyboard mode.
struct KeyboardScreen: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("remotecrab.ios.trackpadSens") private var trackpadSens: Int = 3

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
            IBGradient.canvasDark
                .ignoresSafeArea()

            GeometryReader { geo in
                // Cap the preview so the header + preview + mini trackpad
                // + shortcut bar always fit ABOVE the system keyboard.
                // A fixed preview height overflowed on multi-line text and
                // pushed the lower controls under the keyboard.
                let available = geo.size.height - 56 - keyboardHeight - IBSpace.m.pt
                let reserved: CGFloat = 30 + 96 + 44 + IBSpace.m.pt * 3
                let previewCap = max(44, min(previewMaxHeight, available - reserved))
                VStack(spacing: IBSpace.m.pt) {
                    header
                    previewCard(maxHeight: previewCap)
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
                .padding(.horizontal, IBSpace.s.pt)
                // Clear ContentView's floating top bar (status icon +
                // overflow menu) so the header isn't overlapped.
                .padding(.top, 56)
                .padding(.bottom, IBSpace.m.pt)
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
            // of racing the surface-switch transition.
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
            // Back to the trackpad — the system keyboard covers the
            // bottom PTT row, so the exit needs to live up here.
            Button {
                engine.features.activeSurface = .trackpad
            } label: {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background { IBMaterial.bar(in: Circle()) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.Mode.trackpad)
            Spacer()
            Text(IBLocale.Keyboard.typingOnMac)
                .font(IBFont.eyebrowMono)
                .foregroundStyle(.white.opacity(0.45))
                .ibEyebrowTracking()
        }
        .padding(.horizontal, IBSpace.s.pt)
        .padding(.top, IBSpace.s.pt)
    }

    // MARK: - Preview

    private func previewCard(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityHidden(true)
                Text(IBLocale.Keyboard.onYourMac)
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.white.opacity(0.5))
                    .ibEyebrowTracking()
                Spacer()
                Text(IBLocale.Keyboard.charCount(committedText.count))
                    .font(IBFont.monoMedium)
                    .foregroundStyle(.white.opacity(0.4))
            }
            // Bounded height + scroll: a long message stays fully
            // readable (auto-scrolled to the newest text) without growing
            // the card until the mini trackpad and keys fall off screen.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(committedText.isEmpty
                         ? IBLocale.Keyboard.startTyping
                         : committedText)
                        .font(IBFont.titleMedium)
                        .foregroundStyle(committedText.isEmpty ? .white.opacity(0.35) : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(previewBottomID)
                }
                .frame(maxHeight: maxHeight)
                .frame(minHeight: 36, alignment: .top)
                .onChange(of: committedText) {
                    proxy.scrollTo(previewBottomID, anchor: .bottom)
                }
            }
        }
        .padding(14)
        .background {
            IBMaterial.glass(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
        }
    }

    private let previewBottomID = "preview-bottom"

    /// A few lines of room, then it scrolls. Accessibility text sizes get
    /// more height so wrapping doesn't hide most of the message.
    private var previewMaxHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 220 : 120
    }

    // MARK: - Mini trackpad

    private var miniTrackpad: some View {
        TouchSurface(
            label: IBLocale.A11y.miniTrackpad,
            modifierMask: modifierMask,
            sensitivity: trackpadSens,
            onEvent: { engine.sendTouch($0) }
        )
        .frame(height: 96)
        .background {
            IBMaterial.glass(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
        }
        .overlay {
            // Dashed edge = "this is a touch surface" affordance.
            RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous)
                .strokeBorder(
                    .white.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
        .overlay {
            Text(IBLocale.A11y.miniTrackpad.uppercased())
                .font(IBFont.caption)
                .ibEyebrowTracking()
                .foregroundStyle(.white.opacity(0.2))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Shortcut bar

    private var shortcutBar: some View {
        // Horizontally scrollable: the full row exceeds a 375pt screen,
        // so scrolling keeps every key ≥44pt wide.
        // The context chip is pinned OUTSIDE the ScrollView so it never
        // scrolls away.
        HStack(spacing: 6) {
            contextChip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // ⏎/⌫ lead the row: after voice dictation the next
                    // reach is always "edit" or "send".
                    shortcutKey(symbol: "return", accessibility: IBLocale.A11y.returnKey, keycode: 36, prominent: true)
                    shortcutKey(symbol: "delete.left", accessibility: IBLocale.A11y.deleteKey, keycode: 51)
                    shortcutKey(text: "esc", accessibility: IBLocale.A11y.escapeKey, keycode: 53)
                    shortcutKey(text: "tab", accessibility: IBLocale.A11y.tabKey, keycode: 48)
                    modifierKey(.control)
                    modifierKey(.option)
                    modifierKey(.command)
                    modifierKey(.shift)
                    shortcutKey(symbol: "arrow.left", accessibility: IBLocale.A11y.leftArrowKey, keycode: 123)
                    shortcutKey(symbol: "arrow.right", accessibility: IBLocale.A11y.rightArrowKey, keycode: 124)
                    // App / window switching — borrowed from WhisPrompt's
                    // window wheel and the Codex Micro macropad's "jump to
                    // app" keys, mapped onto macOS's native shortcuts.
                    shortcutKey(text: "⌘⇥", accessibility: IBLocale.Switcher.chordAppSwitcher, keycode: 48, extra: 8)
                    shortcutKey(text: "⌘`", accessibility: IBLocale.Switcher.chordCycleWindows, keycode: 50, extra: 8)
                    shortcutKey(symbol: "rectangle.3.group", accessibility: IBLocale.Switcher.chordMissionControl, keycode: 126, extra: 2)
                    shortcutKey(symbol: "square.on.square", accessibility: IBLocale.Switcher.chordAppExpose, keycode: 125, extra: 2)
                    shortcutKey(text: "⌘H", accessibility: IBLocale.Switcher.chordHideApp, keycode: 4, extra: 8)
                    shortcutKey(text: "⌘Q", accessibility: IBLocale.Switcher.chordQuitApp, keycode: 12, extra: 8)
                }
            }
        }
    }

    /// Frontmost-app context chip, pinned left of the shortcut bar.
    /// Opens the context sheet (Task 7). Data: engine.frontmostMacApp.
    private var contextChip: some View {
        Button {
            engine.showContextSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.frontmostMacApp?.name ?? "Mac")
                    .font(IBFont.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background {
                IBMaterial.glass(
                    in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                    tint: IBColor.accent,
                    interactive: true
                )
            }
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.9))
        .contentShape(RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous))
        .accessibilityLabel(IBLocale.Context.open)
    }

    private func shortcutKey(text: String? = nil, symbol: String? = nil, accessibility: String, keycode: UInt16, extra: UInt8 = 0, prominent: Bool = false) -> some View {
        Button {
            sendKeyTap(keycode, extra: extra)
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
            .foregroundStyle(prominent ? .white : .white.opacity(0.75))
            .frame(width: 44, height: 44)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor)
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
        .buttonStyle(IBPressButtonStyle(scale: 0.9))
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
        .buttonStyle(IBPressButtonStyle(scale: 0.9))
        .accessibilityLabel(modifierAccessibilityLabel(for: modifier))
        .accessibilityValue(locked ? IBLocale.A11y.on : IBLocale.A11y.off)
    }

    private func modifierAccessibilityLabel(for modifier: IBModifierBar.Modifier) -> String {
        switch modifier {
        case .control: return IBLocale.A11y.controlKey
        case .option:  return IBLocale.A11y.optionKey
        case .command: return IBLocale.A11y.commandKey
        case .shift:   return IBLocale.A11y.shiftKey
        }
    }

    // MARK: - Event plumbing

    private func sendKeyTap(_ keycode: UInt16, extra: UInt8 = 0) {
        // `extra` lets a single tap emit a chord (e.g. ⌘⇥) on top of
        // any locked modifiers.
        let mask = modifierMask | extra
        engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: mask))
        engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: mask))
        // Keep the mirror in step with a plain Backspace, or it drifts
        // from what the Mac now shows.
        if keycode == 51, mask == 0, !committedText.isEmpty {
            committedText.removeLast()
        }
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
        // Track the keyboard's own duration/curve so the layout slides
        // in lockstep with it instead of snapping on a default spring.
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        let curve = Self.timingCurve(for: curveRaw)
        withAnimation(.timingCurve(curve.0, curve.1, curve.2, curve.3, duration: duration)) {
            keyboardHeight = max(0, visible - safeAreaBottom)
        }
    }

    /// Map a `UIView.AnimationCurve` (from the keyboard notification)
    /// to SwiftUI cubic Bézier control points. The undocumented system
    /// curve 7 — what the keyboard actually reports — approximates to
    /// (0.32, 0.72, 0, 1).
    private static func timingCurve(for rawValue: UInt?) -> (Double, Double, Double, Double) {
        switch rawValue.flatMap({ UIView.AnimationCurve(rawValue: Int($0)) }) {
        case .easeIn:    return (0.42, 0.0, 1.0, 1.0)
        case .easeOut:   return (0.0, 0.0, 0.58, 1.0)
        case .linear:    return (0.0, 0.0, 1.0, 1.0)
        default:
            if rawValue == 7 { return (0.32, 0.72, 0.0, 1.0) }
            return (0.42, 0.0, 0.58, 1.0) // .easeInOut
        }
    }
}

/// Pressed-state feedback for the shortcut bar — scales the key down
/// while the finger is on it (same idiom as `IBKeyboardKey`).
/// Pressed-state feedback now lives in `IBPressButtonStyle` (RemoteCrabCore).
