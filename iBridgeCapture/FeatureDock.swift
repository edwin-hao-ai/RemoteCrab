import SwiftUI
import UIKit
import iBridgeCore

/// Bottom floating dock — the iOS home screen's single control surface.
///
/// Camera and microphone are background-stream toggles; trackpad and
/// keyboard are foreground surfaces that occupy the screen; voice is a
/// hold-to-talk button that drives the `VoiceRecognizer` speech session.
struct FeatureDock: View {
    let features: FeatureStore
    let voice: VoiceRecognizer
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
        .padding(.horizontal, IBSpace.l.pt)
        .padding(.vertical, IBSpace.s.pt)
        .background {
            IBMaterial.bar(in: RoundedRectangle(cornerRadius: IBRadius.xxl.pt, style: .continuous))
        }
        .onAppear {
            // Recognition session ended on its own (system cap or
            // mid-session error) — un-stick the held/glowing state.
            voice.onInterrupted = {
                voiceHeld = false
                features.set(feature: .voice, enabled: false)
            }
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
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(IBAnimation.snappy) { action() }
        } label: {
            buttonBody(icon: icon, isActive: isOn)
        }
        .buttonStyle(DockPressStyle())
        .accessibilityLabel(label)
    }

    private func surfaceButton(icon: String, surface: Surface, label: String) -> some View {
        let isActive = features.activeSurface == surface
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(IBAnimation.snappy) {
                features.activeSurface = surface
            }
        } label: {
            buttonBody(icon: icon, isActive: isActive)
        }
        .buttonStyle(DockPressStyle())
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
                    startVoice()
                }
                .onEnded { _ in
                    stopVoice()
                }
        )
        .accessibilityLabel(voiceHeld ? "Voice. Release to stop." : "Voice. Hold to talk.")
        .accessibilityAction(named: "Toggle Voice Input") {
            // VoiceOver double-tap can't express "release", so it toggles.
            if voiceHeld {
                stopVoice()
            } else {
                startVoice()
            }
        }
    }

    // MARK: - Voice hold-to-talk

    private func startVoice() {
        guard !voiceHeld else { return }
        voiceHeld = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        features.set(feature: .voice, enabled: true)
        Task { @MainActor in
            let started = await voice.start()
            if !started {
                // No permission / recognizer unavailable — don't leave
                // the button glowing a fake active state.
                voiceHeld = false
                features.set(feature: .voice, enabled: false)
            } else if !voiceHeld {
                // Finger released before the async start() resolved
                // (quick tap) — stop immediately so the recognizer
                // doesn't run on its own until the ~1 min system cap.
                voice.stop()
            }
        }
    }

    private func stopVoice() {
        guard voiceHeld else { return }
        voiceHeld = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        features.set(feature: .voice, enabled: false)
        voice.stop()
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

/// Pressed-state feedback for the dock's tap buttons — scales the
/// button down while the finger is on it.
private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(IBAnimation.snappy, value: configuration.isPressed)
    }
}
