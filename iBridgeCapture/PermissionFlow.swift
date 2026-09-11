import AVFoundation
import Network
import Speech
import SwiftUI
import iBridgeCore

/// The permission-request flow that runs after the user taps
/// "Allow Permissions & Connect" in onboarding.
///
/// Asks for camera, microphone, speech, and local-network permission
/// one at a time with a "request card" between each. Falls back gracefully when
/// a permission is denied (the user can still browse around, just
/// without the relevant feature).
struct PermissionFlow: View {
    let onComplete: () -> Void
    @State private var stage: Stage = .camera
    @State private var results: [Stage: PermissionResult] = [:]

    enum Stage: String, CaseIterable, Identifiable {
        case camera, microphone, speech, localNetwork
        var id: String { rawValue }

        var title: String {
            switch self {
            case .camera:        return IBLocale.Permission.camera
            case .microphone:    return IBLocale.Permission.microphone
            case .speech:        return IBLocale.Permission.speech
            case .localNetwork:  return IBLocale.Permission.localNetwork
            }
        }

        var symbol: String {
            switch self {
            case .camera:        return "camera.fill"
            case .microphone:    return "mic.fill"
            case .speech:        return "waveform"
            case .localNetwork:  return "wifi"
            }
        }

        var reason: String {
            switch self {
            case .camera:        return IBLocale.Permission.cameraReason
            case .microphone:    return IBLocale.Permission.microphoneReason
            case .speech:        return IBLocale.Permission.speechReason
            case .localNetwork:  return IBLocale.Permission.localNetworkReason
            }
        }
    }

    enum PermissionResult {
        case granted
        case denied
        case restricted
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer()
                PermissionCard(
                    stage: stage,
                    result: results[stage],
                    onAllow: { Task { await request(stage) } },
                    onSkip:  { skipCurrent() }
                )
                .id(stage)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .animation(IBAnimation.standard, value: stage)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.06, blue: 0.18),
                Color(red: 0.20, green: 0.06, blue: 0.32)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Permission requests

    private func request(_ stage: Stage) async {
        let result: PermissionResult
        switch stage {
        case .camera:
            result = await requestCamera()
        case .microphone:
            result = await requestMicrophone()
        case .speech:
            result = await requestSpeech()
        case .localNetwork:
            result = await requestLocalNetwork()
        }
        results[stage] = result
        try? await Task.sleep(nanoseconds: 600_000_000)
        advance()
    }

    private func skipCurrent() {
        results[stage] = .denied
        advance()
    }

    private func advance() {
        if let next = Stage.allCases.dropFirst(stageIndex + 1).first {
            stage = next
        } else {
            onComplete()
        }
    }

    private var stageIndex: Int {
        Stage.allCases.firstIndex(of: stage) ?? 0
    }

    // MARK: - OS permission calls

    private func requestCamera() async -> PermissionResult {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    cont.resume(returning: ok ? .granted : .denied)
                }
            }
        @unknown default: return .denied
        }
    }

    private func requestMicrophone() async -> PermissionResult {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    cont.resume(returning: ok ? .granted : .denied)
                }
            }
        @unknown default: return .denied
        }
    }

    private func requestSpeech() async -> PermissionResult {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { auth in
                    cont.resume(returning: auth == .authorized ? .granted : .denied)
                }
            }
        @unknown default: return .denied
        }
    }

    /// Local-network permission can't be queried directly. Triggering
    /// a Bonjour browser is the only way to make iOS show the dialog.
    /// We create a transient browser and immediately cancel it.
    private func requestLocalNetwork() async -> PermissionResult {
        await withCheckedContinuation { (cont: CheckedContinuation<PermissionResult, Never>) in
            let browser = NWBrowser(
                for: .bonjour(type: "_ibridge-probe._tcp", domain: nil),
                using: .tcp
            )
            let lock = NSLock()
            var resolved = false
            let resolve: (PermissionResult) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                if !resolved {
                    resolved = true
                    browser.cancel()
                    cont.resume(returning: result)
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:            resolve(.granted)
                case .failed, .cancelled: resolve(.denied)
                default:                  break
                }
            }
            browser.start(queue: .global())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                resolve(.granted)
            }
        }
    }

    // MARK: - Completion

}

// MARK: - Permission card

private struct PermissionCard: View {
    let stage: PermissionFlow.Stage
    let result: PermissionFlow.PermissionResult?
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(result == .granted ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.18))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                if result == .granted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: stage.symbol)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white)
                }
            }

            Text(stage.title)
                .font(IBFont.titleLarge)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(stage.reason)
                .font(IBFont.bodyMedium)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if result == .granted {
                Text(IBLocale.Permission.granted)
                    .font(IBFont.eyebrowMono)
                    .foregroundStyle(.green)
                    .ibEyebrowTracking()
                    .padding(.top, 8)
            } else if result == .denied {
                Text(IBLocale.Permission.denied)
                    .font(IBFont.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .overlay(alignment: .bottom) {
            if result == nil {
                VStack(spacing: 10) {
                    Button(action: onAllow) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield")
                            Text(IBLocale.Permission.allow)
                        }
                        .font(IBFont.bodyMedium.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background { Capsule().fill(Color.accentColor) }
                    }
                    .buttonStyle(.plain)

                    Button(IBLocale.Permission.notNow, action: onSkip)
                        .font(IBFont.bodySmall)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
    }
}
