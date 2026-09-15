import SwiftUI

/// A keyboard key used in the iOS keyboard-input mode.
/// Handles the press animation, glass background, and labels.
public struct IBKeyboardKey: View {

    public enum Style {
        case letter
        case special       // ⇧ ⌫ 123 🌐 ⏎
        case space
        case modifier      // bottom-row special keys
    }

    let label: String
    let style: Style
    let width: KeyWidth
    let onTap: () -> Void

    @State private var isPressed = false

    public enum KeyWidth {
        case standard
        case wide
        case wider

        var flex: CGFloat {
            switch self {
            case .standard: return 1
            case .wide:     return 2
            case .wider:    return 3
            }
        }
    }

    public init(
        _ label: String,
        style: Style = .letter,
        width: KeyWidth = .standard,
        onTap: @escaping () -> Void = {}
    ) {
        self.label = label
        self.style = style
        self.width = width
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: handleTap) {
            Text(label)
                .font(font)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 42)
                .background(background)
                .overlay {
                    RoundedRectangle(cornerRadius: IBRadius.s.pt + 2, style: .continuous)
                        .stroke(IBColor.borderRegular, lineWidth: 0.5)
                }
                .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .onPressGesture(
            onPress: { isPressed = true },
            onRelease: { isPressed = false; onTap() }
        )
    }

    private var font: Font {
        switch style {
        case .letter:  return IBFont.bodyLarge
        case .special: return IBFont.bodySmall
        case .space:   return IBFont.bodySmall
        case .modifier: return IBFont.bodySmall
        }
    }

    private var textColor: Color {
        switch style {
        case .letter:  return IBColor.textPrimary
        case .special, .modifier: return IBColor.textSecondary
        case .space:   return IBColor.textTertiary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .letter:
            RoundedRectangle(cornerRadius: IBRadius.s.pt + 2, style: .continuous)
                .fill(Color.primary.opacity(isPressed ? 0.15 : 0.08))
        case .space:
            RoundedRectangle(cornerRadius: IBRadius.s.pt + 2, style: .continuous)
                .fill(.clear)
                .overlay {
                    IBMaterial.glass(
                        in: RoundedRectangle(cornerRadius: IBRadius.s.pt + 2, style: .continuous)
                    )
                }
        case .special, .modifier:
            RoundedRectangle(cornerRadius: IBRadius.s.pt + 2, style: .continuous)
                .fill(Color.primary.opacity(isPressed ? 0.18 : 0.10))
        }
    }

    private func handleTap() {
        // Visual feedback handled by onPressGesture.
        withAnimation(IBAnimation.snappy) { isPressed = false }
    }
}

// MARK: - Press gesture

private struct PressGestureModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

extension View {
    /// Detect both quick taps and sustained presses.
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressGestureModifier(onPress: onPress, onRelease: onRelease))
    }
}

#Preview {
    VStack(spacing: 6) {
        HStack(spacing: 4) {
            IBKeyboardKey("q"); IBKeyboardKey("w"); IBKeyboardKey("e"); IBKeyboardKey("r"); IBKeyboardKey("t")
        }
        HStack(spacing: 4) {
            IBKeyboardKey("a"); IBKeyboardKey("s", style: .letter); IBKeyboardKey("d"); IBKeyboardKey("f")
        }
        HStack(spacing: 4) {
            IBKeyboardKey("⇧", style: .special, width: .wide)
            IBKeyboardKey("space", style: .space, width: .wider)
            IBKeyboardKey("⌫", style: .special)
        }
    }
    .padding()
    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .top, endPoint: .bottom))
}