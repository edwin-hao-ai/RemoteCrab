import CryptoKit
import Foundation
import OSLog
import SystemExtensions

/// Submits and tracks activation requests for the embedded CMIO camera
/// extension. The host must run from /Applications for activation to
/// succeed; the user approves in System Settings → General → Login
/// Items & Extensions → Camera Extensions.
///
/// The system records the **origin path of the host app** when an
/// extension is activated. Renaming or moving the app afterwards
/// (iBridgeReceiver.app → Familiar.app) leaves the record behind: it
/// still reads `[activated enabled]` in `systemextensionsctl`, but the
/// host path no longer exists, so the extension is never launched and
/// no camera appears. `ensureRegistered()` detects that the host's path
/// or the extension binary changed since the last successful
/// registration and re-registers it (deactivate → activate).
///
/// Delegate callbacks arrive on the main queue (see `submit`); state is
/// only ever mutated there.
final class SystemExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {

    /// Single shared instance: the `NSApplicationDelegate` runs the
    /// launch-time registration, while SwiftUI reads the published state.
    static let shared = SystemExtensionManager()

    enum ActivationState: Equatable {
        case unknown
        case notInstalled
        case awaitingApproval
        case active
        case repairing
        case failed(String)
    }

    @Published private(set) var activationState: ActivationState = .unknown

    private let log = Logger(subsystem: "com.ibridge", category: "sysex")

    private static let extensionIdentifier = "com.ibridge.iBridgeReceiver.Camera"
    private static let extensionBundleName = "com.ibridge.iBridgeReceiver.Camera.systemextension"
    private static let extensionExecutableName = "com.ibridge.iBridgeReceiver.Camera"

    /// The host path and extension-binary fingerprint recorded the last
    /// time we submitted a request. Compared on every launch so a moved
    /// app or a rebuilt extension triggers exactly one re-registration.
    private static let submittedPathKey = "ibridge.sysexSubmittedAppPath"
    private static let submittedFingerprintKey = "ibridge.sysexSubmittedFingerprint"

    private enum Kind { case activate, deactivate }
    private var pendingKind: Kind = .activate

    /// Set when `repair()` needs to chain an activation after the
    /// deactivation finishes (or fails because nothing was installed).
    private var activateAfterDeactivate = false

    // MARK: - Public entry points

    /// Keeps the system-extension registration in sync with where the
    /// app actually lives. Safe to call on every launch.
    ///
    /// Re-registration is **only** automatic for the case that silently
    /// breaks things: the host app moved/renamed (the system records the
    /// origin path at activation time, so a moved app leaves an orphaned
    /// record that reads "enabled" but never launches).
    ///
    /// A rebuilt extension binary also differs, but replacing an
    /// extension resets the user's approval in System Settings — so that
    /// must stay an explicit user action (Preferences → Re-register),
    /// never an automatic one, or every dev redeploy silently drops the
    /// approval and the camera vanishes.
    func ensureRegistered() {
        let path = Bundle.main.bundlePath
        let recordedPath = UserDefaults.standard.string(forKey: Self.submittedPathKey)

        if recordedPath == nil {
            log.info("first registration; activating camera extension")
            activate()
        } else if recordedPath != path {
            log.info("host app moved \(recordedPath!, privacy: .public) → \(path, privacy: .public); re-registering")
            repair()
        } else {
            log.info("extension registration is up to date")
        }
    }

    /// Submit a plain activation request (Preferences → Activate).
    func activate() {
        submit(kind: .activate)
    }

    /// Re-register from scratch: deactivate the (possibly orphaned)
    /// record, then activate again from the current app location.
    func repair() {
        DispatchQueue.main.async { self.activationState = .repairing }
        activateAfterDeactivate = true
        submit(kind: .deactivate)
    }

    // MARK: - Request plumbing

    private func submit(kind: Kind) {
        pendingKind = kind

        // Record what we're registering before the async callbacks, so a
        // pending approval or a transient failure doesn't cause a
        // deactivate/activate loop on every launch.
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Self.submittedPathKey)
        UserDefaults.standard.set(Self.extensionFingerprint(), forKey: Self.submittedFingerprintKey)

        let request: OSSystemExtensionRequest
        switch kind {
        case .activate:
            request = .activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        case .deactivate:
            request = .deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        }
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted \(kind == .activate ? "activation" : "deactivation", privacy: .public) request for \(Self.extensionIdentifier, privacy: .public)")
    }

    private func finishDeactivation(error: Error?) {
        if let error {
            // Nothing installed (or already removed) — fine, proceed.
            log.info("deactivation finished with error (expected when not installed): \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("deactivation finished")
        }
        guard activateAfterDeactivate else { return }
        activateAfterDeactivate = false
        submit(kind: .activate)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard pendingKind == .activate else { return }
        log.info("activation needs user approval in System Settings")
        DispatchQueue.main.async {
            self.activationState = .awaitingApproval
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("replacing extension \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch pendingKind {
        case .deactivate:
            finishDeactivation(error: nil)
        case .activate:
            log.info("activation finished: \(String(describing: result), privacy: .public)")
            let completed = (result == .completed)
            DispatchQueue.main.async {
                if completed { self.activationState = .active }
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        switch pendingKind {
        case .deactivate:
            finishDeactivation(error: error)
        case .activate:
            log.error("activation failed: \(error.localizedDescription, privacy: .public)")
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.activationState = .failed(message)
            }
        }
    }

    // MARK: - Fingerprint

    /// SHA-256 of the embedded extension executable, used to notice that
    /// a redeploy changed the binary (the system keys approval to the
    /// exact signed binary, so an in-place update needs re-registration).
    private static func extensionFingerprint() -> String? {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(extensionBundleName)/Contents/MacOS/\(extensionExecutableName)")
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
