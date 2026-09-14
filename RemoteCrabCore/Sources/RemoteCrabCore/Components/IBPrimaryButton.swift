import SwiftUI

/// Big circular record-style button with an animated pulsing dot —
/// the design system's primary capture action. Not currently wired
/// to a production screen: streaming is toggled from the iOS
/// connection sheet (a List row, where a 72pt circular button would
/// be out of place). Exercised by `IBDesignSystemShowcase` and the
/// screenshot tooling.
public struct IBPrimaryButton: View {

    public enum Style {
        case stream       // red dot, default start state
        case stop         // white square inside, active state
        case accent       // blue gradient, generic primary action

        var color: Color {
            switch self {
            case .stream: return IBColor.recording
            case .stop:   return IBColor.recording
            case .accent: return IBColor.accent
            }
        }
    }

    let style: Style
    let size: CGFloat
    let onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var isPressed = false

    public init(
        style: Style = .stream,
        size: CGFloat = 72,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        onTap: @escaping () -> Void = {}
    ) {
        self.style = style
        self.size = size
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.onTap = onTap
    }


    private let accessibilityLabel: String?
    private let accessibilityHint: String?

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                if style == .stream {
                    Circle()
                        .stroke(style.color.opacity(0.35), lineWidth: 5)
                        .scaleEffect(pulseScale)
                        .opacity(pulseScale > 1.05 ? 0 : 1)
                }

                Circle()
                    .fill(.white)
                    .frame(width: size - 14, height: size - 14)

                innerShape
            }
            .frame(width: size, height: size)
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(IBAnimation.snappy, value: isPressed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? defaultLabel)
        .accessibilityHint(accessibilityHint ?? defaultHint)
        .onAppear {
            guard style == .stream else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulseScale = 1.45
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var defaultLabel: String {
        switch style {
        case .stream: return IBLocale.Connection.startStreaming
        case .stop:   return IBLocale.Connection.stopStreaming
        case .accent: return "Action"
        }
    }

    private var defaultHint: String {
        switch style {
        case .stream: return "Toggles the iPhone camera feed on or off"
        case .stop:   return "Toggles the iPhone camera feed on or off"
        case .accent: return ""
        }
    }

    @ViewBuilder
    private var innerShape: some View {
        switch style {
        case .stream, .stop:
            Circle()
                .fill(IBColor.recording)
                .frame(width: size * 0.45, height: size * 0.45)
        case .accent:
            Circle()
                .fill(
                    LinearGradient(
                        colors: [IBColor.accent, IBColor.accent.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.45, height: size * 0.45)
        }
    }
}

#Preview {
    HStack(spacing: 30) {
        IBPrimaryButton(style: .stream)
        IBPrimaryButton(style: .stop)
        IBPrimaryButton(style: .accent)
    }
    .padding(40)
    .background(LinearGradient(colors: [.black, .purple], startPoint: .top, endPoint: .bottom))
}