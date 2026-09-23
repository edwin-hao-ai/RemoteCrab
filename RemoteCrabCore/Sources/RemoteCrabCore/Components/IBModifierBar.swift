import SwiftUI

/// Modifier key bar shown in trackpad / keyboard modes.
///
/// Supports ⌃ ⌥ ⌘ ⇧ with a tap-toggle and an exclusive binding.
public struct IBModifierBar: View {

    public struct Key: Identifiable, Hashable {
        public let id: Modifier
        public init(_ id: Modifier) { self.id = id }
    }

    public enum Modifier: String, CaseIterable, Hashable {
        case control = "⌃"
        case option  = "⌥"
        case command = "⌘"
        case shift   = "⇧"

        public var sfSymbol: String {
            switch self {
            case .control: return "control"
            case .option:  return "option"
            case .command: return "command"
            case .shift:   return "shift"
            }
        }

        /// macOS virtual keycode for the LEFT modifier key.
        public var keycode: UInt16 {
            switch self {
            case .control: return 59
            case .option:  return 58
            case .command: return 55
            case .shift:   return 56
            }
        }
    }

    @Binding var activeModifiers: Set<Modifier>

    /// Emits a REAL modifier key down/up. A physical keyboard's held ⌥ is
    /// what opens an input method's panel (e.g. 豆包输入法), shows menu
    /// shortcut hints, etc. — a bitmask applied to later keys can't do
    /// that, so a *hold* sends the actual key event; a quick tap still
    /// toggles the sticky modifier.
    public var onModifierKey: ((_ keycode: UInt16, _ isDown: Bool) -> Void)?

    public init(activeModifiers: Binding<Set<Modifier>>,
                onModifierKey: ((UInt16, Bool) -> Void)? = nil) {
        self._activeModifiers = activeModifiers
        self.onModifierKey = onModifierKey
    }

    /// Press-and-hold threshold before a press counts as a real hold.
    private let holdThreshold: TimeInterval = 0.18
    @State private var holdTasks: [Modifier: Task<Void, Never>] = [:]
    @State private var held: Set<Modifier> = []

    public var body: some View {
        HStack(spacing: IBSpace.s.pt) {
            ForEach(Modifier.allCases, id: \.self) { modifier in
                Button {
                    // No action here: tap vs hold is decided in the style's
                    // press callback, so no gesture competes with a parent
                    // ScrollView's horizontal drag.
                } label: {
                    Text(modifier.rawValue)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(activeModifiers.contains(modifier) ? .white : IBColor.textPrimary)
                        .background {
                            keyBackground(isActive: activeModifiers.contains(modifier))
                        }
                }
                .buttonStyle(PressReportingStyle { pressed in
                    handlePress(modifier, pressed)
                })
                .accessibilityLabel(accessibilityLabel(for: modifier))
                .accessibilityValue(activeModifiers.contains(modifier) ? IBLocale.A11y.on : IBLocale.A11y.off)
            }
        }
    }

    /// Hold sends a REAL modifier key down/up (so a held ⌥ opens an input
    /// method's panel, like a physical keyboard); a quick tap toggles the
    /// sticky modifier. Driven by `isPressed` — NOT a DragGesture, which
    /// would swallow the enclosing ScrollView's drag.
    private func handlePress(_ m: Modifier, _ pressed: Bool) {
        if pressed {
            holdTasks[m]?.cancel()
            holdTasks[m] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(holdThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                held.insert(m)
                onModifierKey?(m.keycode, true)
                withAnimation(IBAnimation.snappy) { activeModifiers.insert(m) }
            }
        } else {
            holdTasks[m]?.cancel()
            holdTasks[m] = nil
            if held.contains(m) {
                held.remove(m)
                onModifierKey?(m.keycode, false)
                withAnimation(IBAnimation.snappy) { activeModifiers.remove(m) }
            } else {
                toggle(m)   // quick tap → sticky modifier
            }
        }
    }

    private func accessibilityLabel(for modifier: Modifier) -> String {
        switch modifier {
        case .control: return IBLocale.A11y.controlKey
        case .option:  return IBLocale.A11y.optionKey
        case .command: return IBLocale.A11y.commandKey
        case .shift:   return IBLocale.A11y.shiftKey
        }
    }

    @ViewBuilder
    private func keyBackground(isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [IBColor.accent, IBColor.accent.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: IBColor.accent.opacity(0.45), radius: 8, y: 4)
        } else {
            IBMaterial.glass(
                in: RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous),
                tint: IBColor.accent,
                interactive: true
            )
        }
    }

    private func toggle(_ m: Modifier) {
        withAnimation(IBAnimation.snappy) {
            if activeModifiers.contains(m) {
                activeModifiers.remove(m)
            } else {
                activeModifiers.insert(m)
            }
        }
    }
}

#Preview {
    StatefulPreviewWrapper(Set<IBModifierBar.Modifier>([.command])) { binding in
        IBModifierBar(activeModifiers: binding)
            .padding()
            .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Reports a Button's pressed state without adding a gesture, so the
/// button still lets an enclosing ScrollView handle a horizontal drag
/// (a `DragGesture(minimumDistance: 0)` would swallow it).
public struct PressReportingStyle: ButtonStyle {
    public var onPressChange: (Bool) -> Void

    public init(onPressChange: @escaping (Bool) -> Void) {
        self.onPressChange = onPressChange
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in
                onPressChange(pressed)
            }
    }
}

/// Tiny utility so we can preview @Binding-driven views.
struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self._value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}