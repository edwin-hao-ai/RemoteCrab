import AppKit
import SwiftUI
import RemoteCrabCore

/// One-click guide for the embedded CMIO camera extension.
///
/// The extension is what makes "RemoteCrab Camera" selectable in FaceTime,
/// Zoom, Photo Booth, OBS, … The system only launches it after the user
/// approves it once in System Settings, so this card drives that whole
/// flow: enable → (system prompt) → deep-link to the right pane →
/// re-register if the app was moved or rebuilt.
struct CameraExtensionCard: View {
    @EnvironmentObject private var sysexManager: SystemExtensionManager

    /// Ground truth, polled while the card is alive: is the CMIO device
    /// actually published? The extension's callbacks only fire for
    /// requests THIS process submitted, so toggling the camera in System
    /// Settings never updates `activationState` — the wizard already
    /// detects via the device list, and the card must not tell a
    /// different story.
    @State private var deviceVisible = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// What the card displays: the real device list wins over the
    /// request-callback state whenever the camera is actually there.
    private var displayedState: SystemExtensionManager.ActivationState {
        deviceVisible ? .active : sysexManager.activationState
    }

    private func refreshDevice() {
        deviceVisible = cmioDevice(uid: IBCameraDevice.uid) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "video.badge.checkmark")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(IBColor.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(IBColor.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(IBLocale.Settings.cameraExtensionTitle)
                        .font(IBFont.titleSmall)
                    statusRow
                }
                Spacer(minLength: 0)
            }

            Text(IBLocale.Settings.cameraExtensionGuide)
                .font(IBFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = sysexManager.activationState {
                Text("\(IBLocale.Settings.sysexFailed): \(message)")
                    .font(IBFont.caption)
                    .foregroundStyle(IBColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                primaryAction
                Button(IBLocale.Settings.reRegister) { sysexManager.repair() }
                    .controlSize(.small)
                    .disabled(isBusy)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(IBColor.borderRegular, lineWidth: 1)
        }
        .onAppear { refreshDevice() }
        .onReceive(poll) { _ in refreshDevice() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 5) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(statusLabel)
                .font(IBFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch displayedState {
        case .awaitingApproval:
            Button(IBLocale.Settings.openExtensions) { openExtensionSettings() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

        case .active:
            Button(IBLocale.Settings.openExtensions) { openExtensionSettings() }
                .controlSize(.small)

        case .repairing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(IBLocale.Settings.sysexRepairing)
                    .font(IBFont.caption)
                    .foregroundStyle(.secondary)
            }

        case .unknown, .notInstalled, .failed:
            Button(IBLocale.Settings.enableCameraExtension) { sysexManager.activate() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    private var isBusy: Bool {
        if case .repairing = sysexManager.activationState { return true }
        return false
    }

    // MARK: - State mapping

    private var statusLabel: String {
        switch displayedState {
        case .unknown, .notInstalled: return IBLocale.Settings.sysexNotInstalled
        case .awaitingApproval:       return IBLocale.Settings.sysexAwaitingApproval
        case .active:                 return IBLocale.Settings.cameraExtensionActiveHint
        case .repairing:              return IBLocale.Settings.sysexRepairing
        case .failed:                 return IBLocale.Settings.sysexFailed
        }
    }

    private var statusIcon: String {
        switch displayedState {
        case .unknown, .notInstalled: return "circle"
        case .awaitingApproval:       return "clock.badge.exclamationmark"
        case .active:                 return "checkmark.circle.fill"
        case .repairing:              return "arrow.triangle.2.circlepath"
        case .failed:                 return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch displayedState {
        case .unknown, .notInstalled: return IBColor.textTertiary
        case .awaitingApproval:       return IBColor.warning
        case .active:                 return IBColor.success
        case .repairing:              return IBColor.accent
        case .failed:                 return IBColor.error
        }
    }

    private func openExtensionSettings() {
        // Prefer the Camera Extensions pane; fall back to the Login Items
        // & Extensions pane, then to System Settings generally.
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
