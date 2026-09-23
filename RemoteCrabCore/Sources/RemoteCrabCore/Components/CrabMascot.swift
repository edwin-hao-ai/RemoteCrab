import SwiftUI

/// The RemoteCrab mascot — the coral crab from the app icon, redrawn as
/// animatable SwiftUI shapes so it can be used for loading / waiting
/// states (the icon itself is a rasterized SVG).
///
/// Same palette as `assets/app-icon-liquid.svg` (coral shell gradient
/// `#FF8A5C → #F95F3C → #E8432D`) plus a Liquid-Glass sheen, so it reads
/// as the same character.
public struct CrabMascot: View {

    /// Bounding size (the shell is ~0.8 of it).
    public var size: CGFloat
    /// Bob + claw-snap animation. Set false for a still mascot.
    public var animated: Bool

    @State private var bob: CGFloat = 0
    @State private var claw: CGFloat = 0

    private static let coralTop = Color(red: 1.00, green: 0.54, blue: 0.36)
    private static let coralMid = Color(red: 0.98, green: 0.37, blue: 0.24)
    private static let coralDeep = Color(red: 0.91, green: 0.26, blue: 0.18)
    private static let leg = Color(red: 0.85, green: 0.28, blue: 0.21)

    public init(size: CGFloat = 96, animated: Bool = true) {
        self.size = size
        self.animated = animated
    }

    private var shellGradient: LinearGradient {
        LinearGradient(colors: [Self.coralTop, Self.coralMid, Self.coralDeep],
                       startPoint: .top, endPoint: .bottom)
    }

    public var body: some View {
        ZStack {
            legs
            clawView(isLeft: true).offset(x: -size * 0.40, y: size * 0.02 + claw)
            clawView(isLeft: false).offset(x: size * 0.40, y: size * 0.02 + claw)

            // Shell
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(shellGradient)
                .frame(width: size * 0.82, height: size * 0.54)
                .overlay {
                    // Glass sheen
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.02), .clear],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .blendMode(.plusLighter)
                }
                .overlay(alignment: .top) {
                    // Eyes
                    HStack(spacing: size * 0.14) {
                        eye
                        eye
                    }
                    .offset(y: -size * 0.10)
                }
                .overlay(alignment: .bottom) {
                    // Smile
                    Capsule()
                        .fill(Self.coralDeep.opacity(0.55))
                        .frame(width: size * 0.16, height: size * 0.03)
                        .offset(y: -size * 0.10)
                }
                .shadow(color: .black.opacity(0.35), radius: size * 0.10, y: size * 0.06)
        }
        .frame(width: size, height: size)
        .offset(y: bob)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                bob = -size * 0.06
            }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                claw = -size * 0.05
            }
        }
        .accessibilityHidden(true)
    }

    private var eye: some View {
        ZStack {
            Circle().fill(.white).frame(width: size * 0.15, height: size * 0.15)
            Circle().fill(Color(white: 0.10)).frame(width: size * 0.075, height: size * 0.075)
                .offset(y: size * 0.008)
            Circle().fill(.white).frame(width: size * 0.028, height: size * 0.028)
                .offset(x: -size * 0.020, y: -size * 0.020)
        }
    }

    private func clawView(isLeft: Bool) -> some View {
        Capsule()
            .fill(shellGradient)
            .frame(width: size * 0.20, height: size * 0.30)
            .rotationEffect(.degrees(isLeft ? 24 : -24))
            .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.03)
    }

    private var legs: some View {
        HStack(spacing: size * 0.30) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Self.leg)
                    .frame(width: size * 0.07, height: size * 0.24)
                    .rotationEffect(.degrees(Double(i - 1) * 16))
            }
        }
        .offset(y: size * 0.26)
    }
}

/// Mascot + a short label, for waiting / loading states.
public struct CrabLoading: View {
    public var message: LocalizedStringKey?
    public var size: CGFloat

    public init(message: LocalizedStringKey? = nil, size: CGFloat = 84) {
        self.message = message
        self.size = size
    }

    public var body: some View {
        VStack(spacing: IBSpace.m.pt) {
            CrabMascot(size: size)
            if let message {
                Text(message)
                    .font(IBFont.caption)
                    .foregroundStyle(IBColor.textSecondary)
            }
        }
    }
}
