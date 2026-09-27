import Foundation
import Combine
import Sparkle
import os
import RemoteCrabCore

/// Owns Sparkle and decides *when* a silently-downloaded update gets
/// installed. The policy is "only while the phone is idle"; the hard part
/// (download, verify, atomic replace, relaunch) is Sparkle's.
@MainActor
final class UpdaterController: NSObject, ObservableObject {

    static let shared = UpdaterController()

    /// True once an update has been downloaded and is waiting for an idle
    /// window (drives the menu-bar "Restart to Update" row).
    @Published private(set) var pendingUpdate = false

    /// Sparkle's silent-install handler, stashed until we're idle.
    private var installHandler: (() -> Void)?

    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()
    private var idleSince: Date?
    private var ticker: Timer?
    private let gate = UpdateInstallGate(dwell: 30)
    private weak var session: ReceiverSession?

    private static let log = Logger(subsystem: "com.remotecrab", category: "updater")

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
    }

    /// Called once from the App; idempotent.
    func attach(session: ReceiverSession) {
        guard self.session == nil else { return }
        self.session = session
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Menu-bar "Restart to Update" — bypass the idle wait on explicit tap.
    func installNow() {
        guard let handler = installHandler else { return }
        Self.log.info("installing pending update on explicit request")
        stopTicker()
        handler()
    }

    // MARK: - Idle gating

    private func beginWaitingForIdle() {
        guard ticker == nil else { return }
        // Low-frequency poll, and only while an update is pending — no
        // always-on timer (project rule: no idle high-frequency ticks).
        ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateIdle() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func evaluateIdle() {
        guard let session, installHandler != nil else { stopTicker(); return }
        let now = Date()
        let active = session.isSessionActive
        let recording = session.isRecording
        if active || recording {
            idleSince = nil
            return
        }
        if idleSince == nil { idleSince = now }
        if gate.shouldInstall(pendingUpdate: true, sessionActive: active,
                              isRecording: recording, idleSince: idleSince, now: now) {
            Self.log.info("installing pending update while idle")
            let handler = installHandler
            stopTicker()
            handler?()
        }
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// Sparkle downloaded an update and would install it on quit. We take
    /// control (return true) so we can install at an idle moment instead;
    /// if the user quits first, Sparkle still installs on termination.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle calls this on the main thread, but the handler is a
        // non-Sendable @escaping closure, so under Swift 6 strict
        // concurrency it can't be captured directly into a @MainActor
        // closure (region-based isolation flags a potential data race).
        // Box it (project pattern) so only a Sendable value crosses.
        let handler = InstallHandlerBox(immediateInstallHandler)
        return MainActor.assumeIsolated {
            Self.log.info("update downloaded; waiting for an idle window")
            installHandler = handler.value
            pendingUpdate = true
            beginWaitingForIdle()
            return true
        }
    }

    /// Test hook: `REMOTECRAB_UPDATE_FEED` overrides the feed URL so a
    /// local appcast can exercise the flow headlessly.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["REMOTECRAB_UPDATE_FEED"]
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    /// Required for menu-bar / LSUIElement apps; without it Sparkle logs a
    /// "gentle reminders unsupported" warning.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// Boxes Sparkle's non-Sendable immediate-install closure so it can cross
/// into a `@MainActor` closure under Swift 6 strict concurrency. Sparkle
/// invokes the delegate on the main thread, so no actual cross-thread
/// hand-off happens.
private struct InstallHandlerBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
}
