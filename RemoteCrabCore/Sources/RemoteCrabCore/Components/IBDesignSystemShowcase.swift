import SwiftUI

/// A single showcase screen for every RemoteCrab Design System component,
/// rendered on top of a vivid background so the Liquid Glass refraction
/// is clearly visible.
///
/// Use this in Xcode Previews to verify a design token change before
/// shipping — every component should look correct together.
public struct IBDesignSystemShowcase: View {

    @State private var modifiers: Set<IBModifierBar.Modifier> = [.command]
    @State private var cameraOn = true
    @State private var micOn = true
    @State private var micLevel: Float = 0.65

    public init() {}

    public var body: some View {
        ZStack {
            background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    IBStatusPill(status: .connected(latencyMs: 24))

                    IBGlassCard(tint: IBColor.accent) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("iPhone 15 Pro")
                                    .font(IBFont.titleMedium)
                                Spacer()
                                Text("● 24ms")
                                    .font(IBFont.monoMedium)
                                    .foregroundStyle(IBColor.success)
                            }
                            Text("Connected · WiFi 5G")
                                .font(IBFont.caption)
                                .foregroundStyle(IBColor.textSecondary)
                            Divider().opacity(0.1)
                            IBToggleRow("Camera", value: "1080p · 30fps", isOn: $cameraOn)
                            IBToggleRow("Microphone", isOn: $micOn)
                            HStack {
                                Text("Mic Level")
                                    .font(IBFont.bodyMedium)
                                    .foregroundStyle(IBColor.textSecondary)
                                Spacer()
                                IBMicMeter(level: micLevel)
                            }
                        }
                    }

                    IBGlassCard(tint: IBColor.accent, radius: .xl, padding: .xl) {
                        VStack(spacing: 16) {
                            Text("Trackpad")
                                .font(IBFont.displayLarge)
                                .ibDisplayTracking()
                            Text("MODE")
                                .font(IBFont.eyebrowMono)
                                .foregroundStyle(IBColor.textTertiary)
                                .ibEyebrowTracking()
                            IBModifierBar(activeModifiers: $modifiers)
                                .padding(.top, 8)
                        }
                    }

                    IBPrimaryButton(style: .stream)
                        .padding(.top, 16)

                    Text("v0.1 · Liquid Glass · iOS 26")
                        .font(IBFont.eyebrowMono)
                        .foregroundStyle(.white.opacity(0.4))
                        .ibEyebrowTracking()
                        .padding(.top, 16)
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.25, blue: 0.55),
                Color(red: 0.45, green: 0.15, blue: 0.50),
                Color(red: 0.20, green: 0.10, blue: 0.45)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    IBDesignSystemShowcase()
}