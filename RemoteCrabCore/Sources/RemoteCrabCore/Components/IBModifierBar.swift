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

        /// The label to show for a **Windows** peer, where the Mac glyphs
        /// (⌃⌥⌘) are meaningless. `command` displays as "Ctrl" because the
        /// Windows receiver maps both the ⌘ and ⌃ bits to Ctrl — so the
        /// muscle-memory `⌘C` on iPhone becomes `Ctrl+C` on the PC.
        public var windowsLabel: String {
            switch self {
            case .control: return "Ctrl"
            case .option:  return "Alt"
            case .command: return "Ctrl"
            case .shift:   return "Shift"
            }
        }
    }

    /// Which OS owns the session — drives the labels only. The wire
    /// semantics (`keycode` + modifier bits) are identical either way.
    public enum PeerPlatform: Hashable {
        case mac
        case windows

        public init(_ raw: String) {
            self = raw.lowercased() == "windows" ? .windows : .mac
        }
    }

    @Binding var activeModifiers: Set<Modifier>

    /// Which platform the peer runs — changes the labels only. Windows
    /// shows Ctrl / Alt / Shift instead of ⌃ / ⌥ / ⌘ / ⇧.
    public var platform: PeerPlatform

    /// Emits a REAL modifier key down/up. A physical keyboard's held ⌥ is
    /// what opens an input method's panel (e.g. 豆包输入法), shows menu
    /// shortcut hints, etc. — a bitmask applied to later keys can't do
    /// that, so a *hold* sends the actual key event; a quick tap still
    /// toggles the sticky modifier.
    public var onModifierKey: ((_ keycode: UInt16, _ isDown: Bool) -> Void)?

    public init(activeModifiers: Binding<Set<Modifier>>,
                platform: PeerPlatform = .mac,
                onModifierKey: ((UInt16, Bool) -> Void)? = nil) {
        self._activeModifiers = activeModifiers
        self.platform = platform
        self.onModifierKey = onModifierKey
    }

    /// Press-and-hold threshold before a press counts as a real hold.
    private let holdThreshold: TimeInterval = 0.18
    @State private var held: Set<Modifier> = []

    public var body: some View {
        HStack(spacing: IBSpace.s.pt) {
            ForEach(Modifier.allCases, id: \.self) { modifier in
                keyView(modifier)
            }
        }
        .onDisappear {
            // Release every locked modifier so a stranded key-down can't
            // turn all later typing into a shortcut.
            for m in activeModifiers { onModifierKey?(m.keycode, false) }
            activeModifiers.removeAll()
        }
    }

    /// Tap toggles the sticky modifier; a press-and-hold sends a REAL
    /// modifier key down/up (so a held ⌥ opens an input method's panel).
    /// `onLongPressGesture` with a `maximumDistance` yields to an enclosing
    /// ScrollView's drag (a DragGesture would swallow it), and the explicit
    /// press callback is more reliable than a ButtonStyle's `isPressed`.
    private func keyView(_ modifier: Modifier) -> some View {
        let active = activeModifiers.contains(modifier)
        let label = platform == .windows ? modifier.windowsLabel : modifier.rawValue
        // Word labels ("Ctrl", "Shift") need a smaller face than the glyphs.
        let font = platform == .windows
            ? Font.system(size: 12, weight: .semibold)
            : Font.system(size: 17, weight: .medium)
        return Text(label)
            .font(font)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .frame(width: 48, height: 48)
            .foregroundStyle(active ? .white : IBColor.textPrimary)
            .background { keyBackground(isActive: active) }
            .contentShape(RoundedRectangle(cornerRadius: IBRadius.m.pt, style: .continuous))
            .onTapGesture { toggle(modifier) }
            .onLongPressGesture(minimumDuration: holdThreshold, maximumDistance: 12) {
                held.insert(modifier)
                onModifierKey?(modifier.keycode, true)
                withAnimation(IBAnimation.snappy) { activeModifiers.insert(modifier) }
            } onPressingChanged: { pressing in
                guard !pressing, held.contains(modifier) else { return }
                held.remove(modifier)
                onModifierKey?(modifier.keycode, false)
                withAnimation(IBAnimation.snappy) { activeModifiers.remove(modifier) }
            }
            .accessibilityLabel(accessibilityLabel(for: modifier))
            .accessibilityValue(active ? IBLocale.A11y.on : IBLocale.A11y.off)
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

    /// Locking a modifier now also emits a REAL modifier key down, so a
    /// locked ⌥ behaves exactly like a held physical ⌥ (which is what
    /// opens an input method's panel) — not just a flag on later events.
    /// Unlocking emits the matching key up.
    private func toggle(_ m: Modifier) {
        withAnimation(IBAnimation.snappy) {
            if activeModifiers.contains(m) {
                activeModifiers.remove(m)
                onModifierKey?(m.keycode, false)
            } else {
                activeModifiers.insert(m)
                onModifierKey?(m.keycode, true)
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