import Foundation

/// Decides whether a downloaded-but-not-yet-installed update may be
/// installed now (silent install + relaunch). Pure, so the "when is it
/// idle enough" policy is unit-tested instead of buried in the app.
public struct UpdateInstallGate: Sendable {

    /// How long the session must stay inactive before we install.
    public let dwell: TimeInterval

    public init(dwell: TimeInterval = 30) {
        self.dwell = dwell
    }

    public func shouldInstall(
        pendingUpdate: Bool,
        sessionActive: Bool,
        isRecording: Bool,
        idleSince: Date?,
        now: Date
    ) -> Bool {
        guard pendingUpdate, !sessionActive, !isRecording, let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= dwell
    }
}
