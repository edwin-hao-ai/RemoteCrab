import Foundation

/// Whether a saved "play the computer's sound on this phone" choice may be
/// resumed when a session has just opened.
///
/// A pure function because the decision is a policy, and because the failure it
/// prevents is invisible: resuming the choice against a Windows receiver turns
/// the microphone **off** (`AudioModeArbiter` ranks the speaker above it), and
/// the control that would explain or undo that is itself hidden behind the same
/// platform check. The user is left with a muted microphone and no reason shown.
public enum SpeakerRestorePolicy {

    /// - Parameters:
    ///   - habit: the persisted choice (`remotecrab.ios.speakerOn`).
    ///   - alreadyOn: the snapshot already has it on, so there is nothing to do.
    ///   - connectedIsWindows: whether the peer is the Windows receiver.
    ///   - e2eForcedMicrophone: a headless run asked for the microphone
    ///     (`REMOTECRAB_E2E_MIC=1`). The flag has to be *authoritative*, and it
    ///     was not: it was applied first and this restore undid it a few lines
    ///     later, so a stale speaker habit made `scripts/e2e-device.sh` report
    ///     "audio packets received" as missing — a failure with nothing to do
    ///     with the code it was testing. The device suite sets the flag, so a
    ///     persisted habit from any earlier session could break it.
    /// - Returns: `true` only when the choice may be applied.
    public static func shouldResume(habit: Bool,
                                    alreadyOn: Bool,
                                    connectedIsWindows: Bool,
                                    e2eForcedMicrophone: Bool = false) -> Bool {
        // An explicit request for the microphone outranks a remembered
        // preference. It has to be here rather than at the call site, because
        // "applied then overwritten" is exactly how this broke.
        if e2eForcedMicrophone { return false }
        guard habit, !alreadyOn else { return false }
        return !connectedIsWindows
    }
}
