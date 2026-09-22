import SwiftUI
import UIKit
import RemoteCrabCore

/// Frontmost-app-aware shortcut sheet. Pure presentation over
/// ContextProfiles (RemoteCrabCore) — key actions replay Mac keyboard
/// events via engine.sendKey; console actions send IBSystemCommand.
struct ContextSheetView: View {
    @EnvironmentObject private var engine: CaptureEngine
    @Environment(\.dismiss) private var dismiss
    @State private var voice = VoiceRecognizer()
    @State private var voiceHeld = false

    private var profile: ContextProfile {
        ContextProfiles.profile(for: engine.frontmostMacApp)
    }

    var body: some View {
        ZStack {
            IBGradient.canvasDark.ignoresSafeArea()
            VStack(spacing: IBSpace.l.pt) {
                header
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(profile.actions.enumerated()), id: \.offset) { _, action in
                        actionButton(action)
                    }
                }
                Spacer()
                Text(IBLocale.Context.footer)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(IBSpace.l.pt)
        }
        .onAppear {
            engine.requestMacApps()  // refresh the frontmost app
            voice.onFinal = { text in
                engine.sendVoiceText(text)
            }
            voice.onInterrupted = {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.frontmostMacApp?.name ?? "Mac")
                    .font(IBFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(.white)
                Text(profile.titleKey.uppercased())
                    .font(IBFont.eyebrowMono)
                    .ibEyebrowTracking()
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(IBSpace.s.pt + 2)
                    .background { IBMaterial.bar(in: Circle()) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .buttonStyle(IBPressButtonStyle())
            .accessibilityLabel(IBLocale.A11y.close)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ContextAction) -> some View {
        switch action {
        case .voiceHero(let label, let symbol):
            heroVoiceButton(label: label, symbol: symbol)
        case .key(let label, let symbol, let keycode, let modifiers):
            contextButton(label: label, symbol: symbol) {
                engine.sendKey(KeyEvent(action: .down, keycode: keycode, modifiers: modifiers))
                engine.sendKey(KeyEvent(action: .up, keycode: keycode, modifiers: modifiers))
            }
        case .system(let label, let symbol, let command):
            contextButton(label: label, symbol: symbol) {
                // launchApp carries its bundle id as the argument;
                // everything else is argument-less.
                let argument: String? = command == .launchApp ? "com.apple.Safari" : nil
                engine.sendSystemCommand(IBSystemCommand(command: command, argument: argument))
            }
        }
    }

    private func contextButton(label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(IBFont.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(13)
            .background {
                IBMaterial.glass(in: RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous))
            }
        }
        .buttonStyle(IBPressButtonStyle(scale: 0.96))
        .accessibilityLabel(label)
    }

    private func heroVoiceButton(label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: voiceHeld)
            Text(voiceHeld ? IBLocale.Voice.releaseToSend : label)
                .font(IBFont.bodyMedium.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background {
            RoundedRectangle(cornerRadius: IBRadius.l.pt, style: .continuous)
                .fill(voiceHeld ? IBColor.recording.opacity(0.85) : Color.accentColor)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startVoice() }
                .onEnded { _ in stopVoice() }
        )
        .accessibilityLabel(label)
    }

    private func startVoice() {
        guard !voiceHeld else { return }
        voiceHeld = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        engine.features.set(feature: .voice, enabled: true)
        Task { @MainActor in
            let started = await voice.start()
            if !started {
                voiceHeld = false
                engine.features.set(feature: .voice, enabled: false)
            } else if !voiceHeld {
                voice.stop()
            }
        }
    }

    private func stopVoice() {
        guard voiceHeld else { return }
        voiceHeld = false
        engine.features.set(feature: .voice, enabled: false)
        voice.stop()
    }
}
