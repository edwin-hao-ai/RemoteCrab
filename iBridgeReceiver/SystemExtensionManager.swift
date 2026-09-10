import Foundation
import OSLog
import SystemExtensions

/// Submits and tracks the activation request for the embedded CMIO
/// camera extension. The host must run from /Applications for
/// activation to succeed; the user approves in System Settings →
/// General → Login Items & Extensions → Camera Extensions.
final class SystemExtensionManager: NSObject, OSSystemExtensionRequestDelegate {

    private let log = Logger(subsystem: "com.ibridge", category: "sysex")
    private static let extensionIdentifier = "com.ibridge.iBridgeReceiver.Camera"

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation request for \(Self.extensionIdentifier, privacy: .public)")
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.info("activation needs user approval in System Settings")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("replacing extension \(existing.bundleShortVersion, privacy: .public) with \(ext.bundleShortVersion, privacy: .public)")
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.info("activation finished: \(String(describing: result), privacy: .public)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log.error("activation failed: \(error.localizedDescription, privacy: .public)")
    }
}
