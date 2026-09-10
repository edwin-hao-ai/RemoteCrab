import SwiftUI
import iBridgeCore

/// Bottom floating dock — the iOS home screen's single control surface.
///
/// Camera and microphone are background-stream toggles; trackpad and
/// keyboard are foreground surfaces that occupy the screen; voice is a
/// hold-to-talk button (state only — recognition wiring lands in Plan 3).
struct FeatureDock: View {
    let features: FeatureStore
    @State private var voiceHeld = false

    var body: some View {
        HStack(spacing: 10) {
            streamToggle(
                icon: "video.fill",
                isOn: features.cameraOn,
                label: features.cameraOn ? "Camera on. Tap to turn off." : "Camera off. Tap to turn on."
            ) {
                features.set(feature: .camera, enabled: !features.cameraOn)
            }

            streamToggle(
                icon: "mic.fill",
                isOn: features.micOn,
                label: features.micOn ? "Microphone on. Tap to turn off." : "Microphone off. Tap to turn on."
            ) {
                features.set(feature: .microphone, enabled: !features.micOn)
            }

            voiceButton

            surfaceButton(
                icon: "hand.point.up.left.fill",
                surface: .trackpad,
                label: "Trackpad"
            )

            surfaceButton(
                icon: "keyboard",
                surface: .keyboard,
                label: "Keyboard"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            IBMaterial.bar(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    // MARK: - Buttons

    private func streamToggle(
        icon: String,
        isOn: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(IBAnimation.snappy) { action() }
        } label: {
            buttonBody(icon: icon, isActive: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func surfaceButton(icon: String, surface: Surface, label: String) -> some View {
        let isActive = features.activeSurface == surface
        return Button {
            withAnimation(IBAnimation.snappy) {
                features.activeSurface = surface
            }
        } label: {
            buttonBody(icon: icon, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Shows the \(label.lowercased()) surface")
    }

    private var voiceButton: some View {
        buttonBody(
            icon: "waveform",
            isActive: voiceHeld,
            activeFill: Color.red.opacity(0.25),
            activeIcon: .red
        )
        .scaleEffect(voiceHeld ? 1.1 : 1.0)
        .animation(IBAnimation.snappy, value: voiceHeld)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !voiceHeld else { return }
                    voiceHeld = true
                    features.set(feature: .voice, enabled: true)
                }
                .onEnded { _ in
                    voiceHeld = false
                    features.set(feature: .voice, enabled: false)
                }
        )
        .accessibilityLabel(voiceHeld ? "Voice. Release to stop." : "Voice. Hold to talk.")
    }

    private func buttonBody(
        icon: String,
        isActive: Bool,
        activeFill: Color = Color.accentColor,
        activeIcon: Color = .white
    ) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? activeIcon : .white.opacity(0.6))
            .frame(width: 48, height: 48)
            .background {
                if isActive {
                    Circle().fill(activeFill)
                } else {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .overlay(Circle().strokeBorder(.white.opacity(0.10)))
                }
            }
    }
}
