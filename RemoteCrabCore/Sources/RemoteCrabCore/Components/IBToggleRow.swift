import SwiftUI

/// Toggle row used in the Mac control panel and iOS settings.
///
/// Glass capsule for the switch + tinted track, label + value on the right.
public struct IBToggleRow: View {

    let label: String
    let value: String?
    @Binding var isOn: Bool

    public init(
        _ label: String,
        value: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.label = label
        self.value = value
        self._isOn = isOn
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(IBFont.bodyMedium)
                .foregroundStyle(IBColor.textSecondary)

            Spacer()

            if let value {
                Text(value)
                    .font(IBFont.monoMedium)
                    .foregroundStyle(IBColor.textPrimary)
                    .ibNumericSpring(value: value)
            }

            toggle
        }
        .padding(.vertical, IBSpace.s.pt + 2)
    }

    private var toggle: some View {
        Button {
            withAnimation(IBAnimation.snappy) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(
                        isOn
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [IBColor.accent, IBColor.accent.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                          )
                        : AnyShapeStyle(Color.primary.opacity(0.15))
                    )
                    .frame(width: 44, height: 26)

                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .padding(2)
            }
            .frame(width: 44, height: 26)
        }
        .buttonStyle(.plain)
        // The self-drawn capsule is a bare Button: without these it
        // announces nothing but "button" to VoiceOver.
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? IBLocale.A11y.on : IBLocale.A11y.off)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    StatefulPreviewWrapper(true) { binding in
        VStack(spacing: 0) {
            IBToggleRow("Camera", value: "1080p · 30fps", isOn: binding)
            Divider().opacity(0.1)
            IBToggleRow("Microphone", isOn: binding)
            Divider().opacity(0.1)
            IBToggleRow("Touchpad", value: nil, isOn: .constant(false))
        }
        .padding()
        .background(
            IBGlassCard(radius: .xl, padding: .l) { Color.clear.frame(height: 0) }
        )
        .padding()
        .background(LinearGradient(colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}