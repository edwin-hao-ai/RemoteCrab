import XCTest
@testable import RemoteCrabCore

/// The rules that decide what the phone's audio hardware does.
///
/// The failure these guard is not a crash — it is the microphone still
/// streaming while the phone plays the computer back, which the user hears
/// as an echo and cannot explain. So the assertions are on the resolved
/// mode, not on any one call site's expression.
final class AudioModeArbiterTests: XCTestCase {

    func testIdleWhenNothingIsOn() {
        XCTAssertEqual(AudioModeArbiter.resolve(micOn: false, voiceOn: false, speakerOn: false), .idle)
    }

    func testMicrophoneAlone() {
        XCTAssertEqual(AudioModeArbiter.resolve(micOn: true, voiceOn: false, speakerOn: false), .microphone)
        XCTAssertTrue(AudioModeArbiter.wantsMicrophone(micOn: true, voiceOn: false, speakerOn: false))
        XCTAssertFalse(AudioModeArbiter.wantsSpeaker(micOn: true, voiceOn: false, speakerOn: false))
    }

    func testSpeakerAlone() {
        XCTAssertEqual(AudioModeArbiter.resolve(micOn: false, voiceOn: false, speakerOn: true), .speaker)
        XCTAssertTrue(AudioModeArbiter.wantsSpeaker(micOn: false, voiceOn: false, speakerOn: true))
        XCTAssertFalse(AudioModeArbiter.wantsMicrophone(micOn: false, voiceOn: false, speakerOn: true))
    }

    /// The load-bearing one: the two cannot coexist, because they claim the
    /// one AVAudioSession in opposite directions.
    func testSpeakerAndMicrophoneResolveToExactlyOneMode() {
        let mode = AudioModeArbiter.resolve(micOn: true, voiceOn: false, speakerOn: true)
        XCTAssertEqual(mode, .speaker)
        XCTAssertFalse(AudioModeArbiter.wantsMicrophone(micOn: true, voiceOn: false, speakerOn: true),
                       "the microphone must stand down or the user hears themselves")
        XCTAssertTrue(AudioModeArbiter.wantsSpeaker(micOn: true, voiceOn: false, speakerOn: true),
                      "the speaker was asked for by name, so it is the one that survives")
    }

    /// Hold-to-talk is a momentary physical press. If the speaker were
    /// allowed to block it, the button would silently do nothing and the
    /// user would press it harder — so voice outranks the speaker.
    func testVoiceOutranksSpeaker() {
        XCTAssertEqual(AudioModeArbiter.resolve(micOn: false, voiceOn: true, speakerOn: true), .voice)
        XCTAssertFalse(AudioModeArbiter.wantsSpeaker(micOn: false, voiceOn: true, speakerOn: true))
    }

    func testVoiceOutranksMicrophone() {
        XCTAssertEqual(AudioModeArbiter.resolve(micOn: true, voiceOn: true, speakerOn: false), .voice)
    }

    /// Every reachable combination must resolve to exactly one mode, and the
    /// three predicates must always agree with that mode. A disagreement
    /// between `wantsMicrophone` and `isRecording` is precisely the bug that
    /// strands a session.
    func testPredicatesAlwaysAgreeWithTheResolvedMode() {
        for mic in [false, true] {
            for voice in [false, true] {
                for speaker in [false, true] {
                    let mode = AudioModeArbiter.resolve(micOn: mic, voiceOn: voice, speakerOn: speaker)
                    let wantsMic = AudioModeArbiter.wantsMicrophone(micOn: mic, voiceOn: voice, speakerOn: speaker)
                    let wantsSpk = AudioModeArbiter.wantsSpeaker(micOn: mic, voiceOn: voice, speakerOn: speaker)
                    let recording = AudioModeArbiter.isRecording(micOn: mic, voiceOn: voice, speakerOn: speaker)

                    XCTAssertEqual(wantsMic, mode == .microphone, "mic=\(mic) voice=\(voice) spk=\(speaker)")
                    XCTAssertEqual(wantsSpk, mode == .speaker, "mic=\(mic) voice=\(voice) spk=\(speaker)")
                    XCTAssertEqual(recording, mode == .microphone || mode == .voice,
                                   "mic=\(mic) voice=\(voice) spk=\(speaker)")
                    XCTAssertFalse(wantsMic && wantsSpk, "two claimants for one audio session")
                    // A playback-only mode must NOT read as "recording", or
                    // applyKeepAlive starts its own .playback session.
                    if mode == .speaker || mode == .idle {
                        XCTAssertFalse(recording, "playback mode must not look like a record session")
                    }
                }
            }
        }
    }
}
