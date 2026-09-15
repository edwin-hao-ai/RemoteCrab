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
    }

    @Binding var activeModifiers: Set<Modifier>

    public init(activeModifiers: Binding<Set<Modifier>>) {
        self._activeModifiers = activeModifiers
    }

    public var body: some View {
        HStack(spacing: IBSpace.s.pt) {
            ForEach(Modifier.allCases, id: \.self) { modifier in
                Button {
                    toggle(modifier)
                } label: {
                    Text(modifier.rawValue)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(activeModifiers.contains(modifier) ? .white : IBColor.textPrimary)
                        .background {
                            keyBackground(isActive: activeModifiers.contains(modifier))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: modifier))
                .accessibilityValue(activeModifiers.contains(modifier) ? IBLocale.A11y.on : IBLocale.A11y.off)
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