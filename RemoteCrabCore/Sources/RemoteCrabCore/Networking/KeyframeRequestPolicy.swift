import Foundation

/// Whether an incoming `requestKeyframe` should reach the encoder.
///
/// Pure because the decision mixes two independent facts — is there a session,
/// and is the camera actually producing anything — and because the failure mode
/// is asymmetric: forcing an intra frame when nothing is streaming has to
/// restart an encoder the user did not ask for, while declining a request from
/// a receiver that is genuinely stuck only costs it one more broken picture.
public enum KeyframeRequestPolicy {

    /// - Parameters:
    ///   - sessionActive: a computer owns the session, so the wire is live.
    ///   - cameraOn: the camera feature is on and the encoder is running.
    public static func shouldForceIntraFrame(sessionActive: Bool,
                                             cameraOn: Bool) -> Bool {
        sessionActive && cameraOn
    }
}
