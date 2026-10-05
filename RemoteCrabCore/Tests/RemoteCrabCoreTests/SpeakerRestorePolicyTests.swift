import XCTest
@testable import RemoteCrabCore

/// A saved "play the computer's sound on this phone" choice must not be
/// resumed against a receiver where the control to undo it is hidden.
final class SpeakerRestorePolicyTests: XCTestCase {

    func test_it_resumes_the_choice_on_a_mac() {
        XCTAssertTrue(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: false, connectedIsWindows: false))
    }

    /// The bug. Resuming against a Windows receiver ranks the speaker above the
    /// microphone, so the microphone goes quiet — and the menu row that could
    /// switch it back on is behind the same platform check.
    func test_it_never_resumes_on_windows() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: false, connectedIsWindows: true))
    }

    func test_no_habit_means_no_restore() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: false, alreadyOn: false, connectedIsWindows: false))
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: false, alreadyOn: false, connectedIsWindows: true))
    }

    /// Idempotent: the snapshot already carries it, so there is nothing to do —
    /// and re-applying would switch the microphone off a second time.
    func test_already_on_is_not_a_second_restore() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: true, connectedIsWindows: false))
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: true, connectedIsWindows: true))
    }

    /// The microphone must not be collateral damage on any platform: the policy
    /// decides whether the speaker resumes, never whether the mic keeps running.
    func test_the_policy_has_no_opinion_about_the_microphone() {
        // Same inputs, both platforms — the only thing that flips the answer is
        // the platform, which is what makes this a policy and not a side effect.
        XCTAssertNotEqual(
            SpeakerRestorePolicy.shouldResume(habit: true, alreadyOn: false, connectedIsWindows: false),
            SpeakerRestorePolicy.shouldResume(habit: true, alreadyOn: false, connectedIsWindows: true))
    }
    /// The headless microphone request outranks a remembered speaker habit.
    ///
    /// It did not, and the failure was misattributed for a while: the flag was
    /// applied first, this restore undid it a few lines later, and
    /// `scripts/e2e-device.sh` then reported "audio packets received" as
    /// missing — pointing at the audio path when the cause was a stale
    /// preference from an earlier interactive session.
    func testAForcedMicrophoneSuppressesTheRememberedSpeakerHabit() {
        XCTAssertFalse(SpeakerRestorePolicy.shouldResume(
            habit: true, alreadyOn: false, connectedIsWindows: false,
            e2eForcedMicrophone: true),
            "the speaker would take the audio session and the microphone would stand down")
    }

    /// And it changes nothing when no headless run is asking.
    func testTheForcedMicrophoneFlagDefaultsToOff() {
        XCTAssertEqual(
            SpeakerRestorePolicy.shouldResume(habit: true, alreadyOn: false, connectedIsWindows: false),
            SpeakerRestorePolicy.shouldResume(habit: true, alreadyOn: false, connectedIsWindows: false,
                                              e2eForcedMicrophone: false))
    }

}
