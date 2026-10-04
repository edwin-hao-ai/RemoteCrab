import Foundation

/// The one place that decides what the phone's audio hardware is doing.
///
/// This exists because the answer used to be written as the expression
/// `micOn && !voiceOn` in TWO places in `CaptureEngine` (the live path and
/// the reconnect path), with `applyKeepAlive`'s `micOn || voiceOn` as its
/// De Morgan complement in a third. Adding the speaker mode to that set
/// meant touching all three, and forgetting one does not fail loudly — it
/// leaves the microphone streaming while the phone plays the computer back,
/// which is an echo loop the user hears immediately but cannot diagnose.
///
/// So the rules live here, pure and tested, and the engine asks.
public enum AudioMode: Sendable, Equatable {
    /// Nothing is being captured or played.
    case idle
    /// The phone's microphone is streaming to the computer.
    case microphone
    /// Hold-to-talk is capturing for dictation.
    case voice
    /// The computer's audio is playing out of the phone speaker.
    case speaker
}

/// Resolves the two INDEPENDENT flags (`micOn`, `speakerOn`) into the one
/// mode the hardware can actually be in.
///
/// The flags stay separate on purpose — the user-facing controls are two
/// toggles sharing one dropdown, like the mirror menu's two sources, and the
/// computer's control panel shows them as two features. This type is the
/// SAFETY layer underneath: the two cannot both be on, so something has to
/// decide which one wins when a snapshot or a reconnect says both are.
///
/// The phone cannot stream its microphone to the computer and play the
/// computer's audio back at the same time — one `AVAudioSession`, two
/// directions. So the tie is broken here rather than in the UI, which keeps
/// the two controls independent while making the impossible state
/// unreachable.
///
/// Precedence, and why:
///
/// 1. **Voice wins over everything.** Hold-to-talk is a momentary physical
///    act; if it were refused because the speaker was playing, the button
///    would silently do nothing and the user would press it harder.
/// 2. **Speaker wins over the microphone.** Both claim the one
///    `AVAudioSession` in opposite directions, so they cannot run together.
///    Speaker wins because it is the mode the user just asked for by name,
///    and quietly cancelling the microphone is more surprising than
///    cancelling the phone-as-speaker.
/// 3. **The microphone otherwise**, if it is on.
///
/// `voiceOn` deliberately outranks `speakerOn` even though that means
/// turning the speaker on can be interrupted: the two are already
/// incompatible, and a momentary press must never be the thing that loses.
public enum AudioModeArbiter {

    public static func resolve(cameraOn: Bool = false,
                               micOn: Bool,
                               voiceOn: Bool,
                               speakerOn: Bool) -> AudioMode {
        if voiceOn { return .voice }
        if speakerOn { return .speaker }
        if micOn { return .microphone }
        return .idle
    }

    /// Whether the microphone encoder should be running.
    public static func wantsMicrophone(cameraOn: Bool = false,
                                       micOn: Bool,
                                       voiceOn: Bool,
                                       speakerOn: Bool) -> Bool {
        resolve(cameraOn: cameraOn, micOn: micOn, voiceOn: voiceOn,
                speakerOn: speakerOn) == .microphone
    }

    /// Whether a *record* session is nominally on. `applyKeepAlive` needs the
    /// De Morgan complement of `wantsMicrophone`: while the phone is
    /// SPEAKING, its session is `.playback`, and letting the keep-alive
    /// start its own `.playback` would have two claimants racing for one
    /// session — redundant at best and `'!pri'` at worst.
    public static func isRecording(micOn: Bool, voiceOn: Bool, speakerOn: Bool) -> Bool {
        resolve(micOn: micOn, voiceOn: voiceOn, speakerOn: speakerOn) == .microphone
            || resolve(micOn: micOn, voiceOn: voiceOn, speakerOn: speakerOn) == .voice
    }

    /// Whether the phone-speaker player should be running.
    public static func wantsSpeaker(micOn: Bool, voiceOn: Bool, speakerOn: Bool) -> Bool {
        resolve(micOn: micOn, voiceOn: voiceOn, speakerOn: speakerOn) == .speaker
    }
}
