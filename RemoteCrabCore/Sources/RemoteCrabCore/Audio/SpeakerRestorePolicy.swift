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
    /// - Returns: `true` only when the choice may be applied.
    public static func shouldResume(habit: Bool,
                                    alreadyOn: Bool,
                                    connectedIsWindows: Bool) -> Bool {
        guard habit, !alreadyOn else { return false }
        return !connectedIsWindows
    }
}
