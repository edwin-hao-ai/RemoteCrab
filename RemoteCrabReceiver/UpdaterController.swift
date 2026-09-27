import Foundation
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

    /// Created lazily, on first use, rather than in `init()`. Starting
    /// Sparkle from `App.init()` is too early — the app's connection to
    /// system services isn't up yet (the same class of problem as the
    /// camera system-extension registration; see `AppDelegate`). The app
    /// calls `attach(session:)` from `applicationDidFinishLaunching`,
    /// which materializes this.
    // The check/auto-download defaults live in Info.plist
    // (`SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`), NOT as
    // assignments here: Sparkle persists these in UserDefaults, and
    // setting them on every launch would silently override the user's
    // Preferences toggle (Sparkle's own header warns against it).
    private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()

    private var idleSince: Date?
    private var ticker: Timer?
    private let gate = UpdateInstallGate(dwell: 30)
    private weak var session: ReceiverSession?

    private static let log = Logger(subsystem: "com.remotecrab", category: "updater")

    private override init() {
        super.init()
    }

    /// Called once from the App's `applicationDidFinishLaunching`;
    /// idempotent. Also starts Sparkle (the lazy controller is touched
    /// here) so the updater never begins before AppKit has launched.
    func attach(session: ReceiverSession) {
        guard self.session == nil else { return }
        self.session = session
        _ = controller
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
        guard let handler = consumeInstallHandler() else { return }
        Self.log.info("installing pending update on explicit request")
        handler()
    }

    // MARK: - Idle gating

    /// Takes the stashed install handler so it can only ever be invoked
    /// once. Clears the pending state and the ticker synchronously, so a
    /// tick Task enqueued before an explicit `installNow()` (or vice versa)
    /// finds nothing to do. Returns nil if there is no pending install.
    private func consumeInstallHandler() -> (() -> Void)? {
        guard let handler = installHandler else { return nil }
        installHandler = nil
        pendingUpdate = false
        idleSince = nil
        stopTicker()
        return handler
    }

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
        // Only a live ticker with a still-pending handler may install; a
        // tick Task that outlives the ticker must not fire a second
        // install (the handler is consumed synchronously below).
        guard let session, ticker != nil, installHandler != nil else {
            stopTicker()
            return
        }
        let now = Date()
        let active = session.isSessionActive
        let recording = session.isRecording
        if active || recording {
            idleSince = nil
            return
        }
        if idleSince == nil { idleSince = now }
        if gate.shouldInstall(pendingUpdate: pendingUpdate, sessionActive: active,
                              isRecording: recording, idleSince: idleSince, now: now),
           let handler = consumeInstallHandler() {
            Self.log.info("installing pending update while idle")
            handler()
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

    /// Observability (spec §9): report a failed update cycle. Sparkle still
    /// passes a non-nil error for routine outcomes — no newer version found
    /// (`SUNoUpdateError`) or a user-cancelled install
    /// (`SUInstallationCanceledError`) — so those are filtered out instead of
    /// logged as failures. Sparkle invokes driver callbacks on the main
    /// thread, so `assumeIsolated` is safe (same as the method above).
    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard let error, !Self.isRoutineUpdateOutcome(error) else { return }
        MainActor.assumeIsolated {
            Self.log.error("update cycle failed (\(String(describing: updateCheck), privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Observability (spec §9): report a driver abort (e.g. a failed
    /// download or a bad signature). A cancelled install reaches here too and
    /// is not a failure.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard !Self.isRoutineUpdateOutcome(error) else { return }
        MainActor.assumeIsolated {
            Self.log.error("update driver aborted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True for Sparkle outcomes that are not failures: no newer version is
    /// available, or the user cancelled an install (see `SUErrors.h`).
    private nonisolated static func isRoutineUpdateOutcome(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == SUSparkleErrorDomain else { return false }
        return ns.code == Int(SUError.noUpdateError.rawValue)
            || ns.code == Int(SUError.installationCanceledError.rawValue)
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
