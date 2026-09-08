import SwiftUI

/// Generic Liquid Glass card container. The visual foundation
/// of iBridge — every panel, menu, and floating control uses this.
public struct IBGlassCard<Content: View>: View {

    private let content: Content
    private let tint: Color
    private let radius: IBRadius
    private let padding: IBSpace

    public init(
        tint: Color = IBColor.accent,
        radius: IBRadius = .l,
        padding: IBSpace = .l,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.tint = tint
        self.radius = radius
        self.padding = padding
    }

    public var body: some View {
        content
            .padding(padding.pt)
            .background {
                IBMaterial.glass(
                    in: RoundedRectangle(cornerRadius: radius.pt, style: .continuous),
                    tint: tint,
                    interactive: true
                )
            }
    }
}

#Preview("Card — Default") {
    ZStack {
        backgroundGradient.ignoresSafeArea()
        IBGlassCard {
            VStack(alignment: .leading, spacing: IBSpace.s.pt) {
                Text("iPhone 15 Pro")
                    .font(IBFont.titleMedium)
                Text("● 24ms")
                    .font(IBFont.monoMedium)
                    .foregroundStyle(IBColor.success)
            }
        }
        .frame(width: 280)
    }
}

private var backgroundGradient: LinearGradient {
    LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.30, blue: 0.60),
            Color(red: 0.40, green: 0.10, blue: 0.50)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}