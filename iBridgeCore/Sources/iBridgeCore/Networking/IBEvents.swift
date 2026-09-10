import Foundation

/// A single touch / mouse event captured on the iPhone and shipped
/// over the wire to the Mac, which injects it via `CGEventPost`.
///
/// Coordinates are normalized to `0 ... 1` against the iPhone screen.
/// The Mac remaps them against its display rectangle when posting.
public struct TouchEvent: Codable, Sendable, Equatable {

    public enum Phase: String, Codable, Sendable {
        case down          // single-finger tap-down = left mouse down
        case move          // single-finger drag = mouse move
        case up            // single-finger tap-up = left mouse up
        case rightDown     // two-finger tap-down = right mouse down
        case rightUp       // two-finger tap-up = right mouse up
        case scroll        // two-finger drag = scroll wheel
        case click         // tap (down + up in same spot) = left click
        case dragStart        // double-tap-hold: begin drag (left button held)
        case pinch            // two-finger pinch; dx = scale delta (+0.01 = +1%)
        case threeFingerSwipe // dx/dy = unit direction vector (up = (0,1))
        case threeFingerTap   // three-finger tap = middle click
        case forceClick       // deep press (majorRadius) = right click
    }

    public enum Modifier: UInt8, Codable, Sendable {
        case none    = 0
        case shift   = 1
        case control = 2
        case option  = 4
        case command = 8
    }

    public let phase: Phase
    public let x: Float           // normalized 0..1
    public let y: Float
    public let dx: Float          // delta for move / scroll
    public let dy: Float
    public let modifiers: UInt8
    public let timestampMicros: UInt64

    public init(
        phase: Phase,
        x: Float = 0,
        y: Float = 0,
        dx: Float = 0,
        dy: Float = 0,
        modifiers: UInt8 = 0,
        timestampMicros: UInt64 = 0
    ) {
        self.phase = phase
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.modifiers = modifiers
        self.timestampMicros = timestampMicros
    }

    public var hasCommand: Bool { modifiers & Modifier.command.rawValue != 0 }
    public var hasShift:   Bool { modifiers & Modifier.shift.rawValue   != 0 }
    public var hasOption:  Bool { modifiers & Modifier.option.rawValue  != 0 }
    public var hasControl: Bool { modifiers & Modifier.control.rawValue != 0 }
}

/// A single key event from the iPhone keyboard.
///
/// Two modes of operation:
///
/// 1. `.down` / `.up` events carry a USB HID `keycode` so the Mac
///    can post a faithful "real key press" via `CGEventPost`.
/// 2. `.text` events carry a UTF-8 string already translated by the
///    iOS IME (predictive text, autocorrect, etc). The Mac posts
///    the string via `CGEventCreateKeyboardEvent` with no keycode.
public struct KeyEvent: Codable, Sendable, Equatable {

    public enum Action: String, Codable, Sendable {
        case down
        case up
        case text      // batch of typed characters (finalized after IME)
    }

    public let action: Action
    public let keycode: UInt16?     // USB HID usage ID, present for .down/.up
    public let text: String?        // present for .text
    public let modifiers: UInt8
    public let timestampMicros: UInt64

    public init(
        action: Action,
        keycode: UInt16? = nil,
        text: String? = nil,
        modifiers: UInt8 = 0,
        timestampMicros: UInt64 = 0
    ) {
        self.action = action
        self.keycode = keycode
        self.text = text
        self.modifiers = modifiers
        self.timestampMicros = timestampMicros
    }
}

/// A single Opus-encoded audio frame from the iPhone microphone.
///
/// `opusData` is one Opus packet (typically 20 ms at 48 kHz).
/// `sampleRate` is included for clarity even though Opus is
/// sample-rate-agnostic — it lets the receiver pick a matching
/// playback graph.
public struct AudioPacket: Codable, Sendable, Equatable {

    public let opusData: Data
    public let sampleRate: Int
    public let channels: Int
    public let timestampMicros: UInt64

    public init(
        opusData: Data,
        sampleRate: Int = 48_000,
        channels: Int = 1,
        timestampMicros: UInt64 = 0
    ) {
        self.opusData = opusData
        self.sampleRate = sampleRate
        self.channels = channels
        self.timestampMicros = timestampMicros
    }

    // MARK: - Codable (Data is not Codable by default)

    private enum CodingKeys: String, CodingKey {
        case opusData, sampleRate, channels, timestampMicros
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base64 = try c.decode(String.self, forKey: .opusData)
        guard let data = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .opusData, in: c,
                debugDescription: "opusData is not valid base64"
            )
        }
        opusData = data
        sampleRate = try c.decode(Int.self, forKey: .sampleRate)
        channels = try c.decode(Int.self, forKey: .channels)
        timestampMicros = try c.decode(UInt64.self, forKey: .timestampMicros)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opusData.base64EncodedString(), forKey: .opusData)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channels, forKey: .channels)
        try c.encode(timestampMicros, forKey: .timestampMicros)
    }
}

/// The independently toggleable capabilities of an iPhone running
/// iBridgeCapture. `.camera / .microphone / .voice` are background
/// streams; `.trackpad / .keyboard` are input channels.
public enum IBFeature: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case voice
    case trackpad
    case keyboard
}

/// Mac → iPhone: toggle a feature remotely (kind 0x07).
public struct FeatureControl: Codable, Sendable, Equatable {
    public let feature: IBFeature
    public let enabled: Bool

    public init(feature: IBFeature, enabled: Bool) {
        self.feature = feature
        self.enabled = enabled
    }
}

/// Which interaction surface currently occupies the iPhone screen.
public enum Surface: String, Codable, Sendable {
    case trackpad
    case keyboard
    case cameraPreview
}

/// iPhone → Mac: full feature-state snapshot (kind 0x08), sent on
/// connect and on every change.
public struct FeatureStateSnapshot: Codable, Sendable, Equatable {
    public let cameraOn: Bool
    public let micOn: Bool
    public let voiceOn: Bool
    public let trackpadOn: Bool
    public let keyboardOn: Bool
    public let activeSurface: Surface
    public let timestampMicros: UInt64

    public init(
        cameraOn: Bool,
        micOn: Bool,
        voiceOn: Bool,
        trackpadOn: Bool,
        keyboardOn: Bool,
        activeSurface: Surface,
        timestampMicros: UInt64
    ) {
        self.cameraOn = cameraOn
        self.micOn = micOn
        self.voiceOn = voiceOn
        self.trackpadOn = trackpadOn
        self.keyboardOn = keyboardOn
        self.activeSurface = activeSurface
        self.timestampMicros = timestampMicros
    }
}