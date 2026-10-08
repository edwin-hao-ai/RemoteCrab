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
        /// The Windows key (⊞). Bit 16 was unused in the original mask.
        ///
        /// Needed because `command` collapses into Ctrl on Windows, so
        /// without a bit of its own the ⊞ chords (⊞E / ⊞R / ⊞D / ⊞L)
        /// were unreachable from the phone — `keymap.rs` could already
        /// send a bare ⊞ but had no way to hold it.
        ///
        /// The Mac receiver has no ⊞ and `CGEventInjector.eventFlags`
        /// ignores bits it does not know, so a stray 16 is inert there.
        case meta    = 16
    }

    public let phase: Phase
    public let x: Float           // normalized 0..1
    public let y: Float
    public let dx: Float          // delta for move / scroll
    public let dy: Float
    public let modifiers: UInt8
    /// True when this .scroll event comes from the iOS-side momentum
    /// glide (finger already lifted). The Mac maps these onto
    /// kCGScrollWheelEventMomentumPhase so the system applies native
    /// inertia/rubber-banding instead of treating it as finger input.
    /// Optional for wire compatibility with older senders.
    public let momentum: Bool?
    public let timestampMicros: UInt64

    public init(
        phase: Phase,
        x: Float = 0,
        y: Float = 0,
        dx: Float = 0,
        dy: Float = 0,
        modifiers: UInt8 = 0,
        momentum: Bool? = nil,
        timestampMicros: UInt64 = 0
    ) {
        self.phase = phase
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.modifiers = modifiers
        self.momentum = momentum
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
/// 1. `.down` / `.up` events carry a macOS CGKeyCode (virtual
///    keycode) so the Mac can post a faithful "real key press"
///    via `CGEventPost`.
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
    public let keycode: UInt16?     // macOS CGKeyCode (virtual keycode), present for .down/.up
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

/// A single audio frame from the iPhone microphone.
///
/// `opusData` carries one Opus packet (typically 20 ms at 48 kHz) when
/// `codec == "opus"`, or raw Int16 interleaved PCM when `codec == "pcm"`.
/// `sampleRate` is included for clarity even though Opus is
/// sample-rate-agnostic — it lets the receiver pick a matching
/// playback graph.
public struct AudioPacket: Codable, Sendable, Equatable {

    /// Wire value for raw Int16 PCM payloads.
    public static let codecPCM = "pcm"
    /// Wire value for Opus payloads (AudioConverter, 48 kHz mono).
    public static let codecOpus = "opus"

    public let opusData: Data
    public let sampleRate: Int
    public let channels: Int
    public let timestampMicros: UInt64
    /// Payload format: "pcm" (legacy, default) or "opus". Older builds
    /// omit the key entirely, so decoding must default to "pcm".
    public let codec: String

    public init(
        opusData: Data,
        sampleRate: Int = 48_000,
        channels: Int = 1,
        timestampMicros: UInt64 = 0,
        codec: String = codecPCM
    ) {
        self.opusData = opusData
        self.sampleRate = sampleRate
        self.channels = channels
        self.timestampMicros = timestampMicros
        self.codec = codec
    }

    // MARK: - Codable (Data is not Codable by default)

    private enum CodingKeys: String, CodingKey {
        case opusData, sampleRate, channels, timestampMicros, codec
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
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? Self.codecPCM
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opusData.base64EncodedString(), forKey: .opusData)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channels, forKey: .channels)
        try c.encode(timestampMicros, forKey: .timestampMicros)
        try c.encode(codec, forKey: .codec)
    }
}

/// The independently toggleable capabilities of an iPhone running
/// RemoteCrabCapture. `.camera / .microphone / .voice` are background
/// streams; `.trackpad / .keyboard` are input channels.
public enum IBFeature: String, Codable, Sendable, CaseIterable {
    case camera
    case microphone
    case voice
    case trackpad
    case keyboard
    /// Mac app-window mirror (`screenControl` / `screenInput` / `screenInfo`).
    case screen
    /// The computer's audio plays out of the iPhone speaker. Mutually
    /// exclusive with `.microphone`: both claim the one `AVAudioSession`,
    /// in opposite directions. A phone cannot stream its mic to the
    /// computer and play the computer back at the same time, and pretending
    /// otherwise with two independent toggles would be a control that lies.
    case speaker
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

/// Which physical camera the iPhone streams from.
public enum IBCameraPosition: String, Codable, Sendable, CaseIterable {
    case front
    case back

    public var toggled: IBCameraPosition { self == .back ? .front : .back }
}

/// Mac → iPhone: switch the streaming camera (kind 0x15). One-shot
/// action, not a toggle — the iPhone reconfigures its capture session
/// and reports the new position back in its next `FeatureStateSnapshot`.
public struct IBCameraCommand: Codable, Sendable, Equatable {
    public let position: IBCameraPosition

    public init(position: IBCameraPosition) {
        self.position = position
    }
}

/// Which interaction surface currently occupies the iPhone screen.
public enum Surface: String, Codable, Sendable {
    case trackpad
    case keyboard
    case cameraPreview
    /// Live mirror of the Mac's frontmost application window.
    case screen
}

/// iPhone → Mac: full feature-state snapshot (kind 0x08), sent on
/// connect and on every change.
public struct FeatureStateSnapshot: Codable, Sendable, Equatable {
    public let cameraOn: Bool
    public let micOn: Bool
    public let voiceOn: Bool
    public let trackpadOn: Bool
    public let keyboardOn: Bool
    /// Whether the Mac app-window mirror is live. Defaults to false for
    /// snapshots from older builds.
    public let screenOn: Bool
    /// Whether the computer's audio is playing on the phone speaker.
    /// Defaults to false for snapshots from older builds — WITHOUT this
    /// default a snapshot from a peer that predates the feature throws in
    /// `init(from:)` below, and both ends swallow decode errors, so every
    /// paired phone would silently lose its whole feature state.
    public let speakerOn: Bool
    public let activeSurface: Surface
    /// Which camera is streaming. Defaults to `.back` when absent so
    /// snapshots from older builds still decode.
    public let cameraPosition: IBCameraPosition
    public let timestampMicros: UInt64

    public init(
        cameraOn: Bool,
        micOn: Bool,
        voiceOn: Bool,
        trackpadOn: Bool,
        keyboardOn: Bool,
        activeSurface: Surface,
        screenOn: Bool = false,
        speakerOn: Bool = false,
        cameraPosition: IBCameraPosition = .back,
        timestampMicros: UInt64
    ) {
        self.cameraOn = cameraOn
        self.micOn = micOn
        self.voiceOn = voiceOn
        self.trackpadOn = trackpadOn
        self.keyboardOn = keyboardOn
        self.screenOn = screenOn
        self.speakerOn = speakerOn
        self.activeSurface = activeSurface
        self.cameraPosition = cameraPosition
        self.timestampMicros = timestampMicros
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraOn = try c.decode(Bool.self, forKey: .cameraOn)
        micOn = try c.decode(Bool.self, forKey: .micOn)
        voiceOn = try c.decode(Bool.self, forKey: .voiceOn)
        trackpadOn = try c.decode(Bool.self, forKey: .trackpadOn)
        keyboardOn = try c.decode(Bool.self, forKey: .keyboardOn)
        screenOn = try c.decodeIfPresent(Bool.self, forKey: .screenOn) ?? false
        speakerOn = try c.decodeIfPresent(Bool.self, forKey: .speakerOn) ?? false
        activeSurface = try c.decode(Surface.self, forKey: .activeSurface)
        cameraPosition = try c.decodeIfPresent(IBCameraPosition.self, forKey: .cameraPosition) ?? .back
        timestampMicros = try c.decode(UInt64.self, forKey: .timestampMicros)
    }
}

/// Mac → iPhone: identity handshake sent as the first frame on every
/// connection (kind `0x0A`). The iPhone decides whether to serve this
/// Mac based on `id` / `token` before it sends any stream data.
public struct IBClientHello: Codable, Sendable, Equatable {
    public let name: String
    /// Stable per-computer UUID, persisted across launches.
    public let id: String
    /// Pairing token issued by the iPhone on first approval. nil on the
    /// very first connection (nothing to present yet).
    public let token: String?
    public let appVersion: String
    /// Which OS the peer runs: `"macos"` / `"windows"` / `"linux"`.
    ///
    /// ADDITIVE + OPTIONAL: older Macs don't send it, so decoding defaults
    /// to nil and callers must treat nil as `"macos"`. The iPhone uses it
    /// to show the right modifier symbols (⌘⇧ vs Ctrl/Alt) and the right
    /// shortcut chords for the connected computer.
    public var platform: String?

    /// What this receiver can cope with, declared up front so the phone can
    /// stay quiet instead of probing into a wall.
    ///
    /// ADDITIVE + OPTIONAL, and **absence means "nothing"**. A Mac app from
    /// before 1.1 omits the field entirely, so the phone's behaviour against
    /// it is identical to what 1.0 did — no latency probes (which such a
    /// receiver misreads as its own echo and turns into a multi-hour "latency"
    /// in its menu bar) and no wait for command results it will never send.
    public var capabilities: [Capability]?

    /// This receiver's half of the identity challenge, base64.
    ///
    /// ADDITIVE + OPTIONAL. Absent from a receiver built before this exchange
    /// existed, and **absence is what makes the phone treat the session as
    /// unauthenticated (legacy)** rather than demand a proof the receiver cannot
    /// give. A receiver that sends it expects a `clientProof` back — see
    /// `PeerAuth`.
    public var nonce: String?

    /// Declared abilities. Raw values, because an unknown string from a newer
    /// peer must decode rather than fail the whole handshake.
    public enum Capability: String, Codable, Sendable, Equatable {
        /// The receiver echoes probes it did not originate, so a phone can
        /// measure its own round trip.
        case latencyProbe
        /// The receiver answers commands with `commandResult` (0x23).
        case commandResult
        /// The receiver can prove its identity with a challenge-response and
        /// verify the phone's. Declared alongside `nonce`; `nonce` is what the
        /// phone actually keys off.
        case peerAuth
    }

    public init(name: String, id: String, token: String? = nil,
                appVersion: String = "", platform: String? = nil,
                capabilities: [Capability]? = nil, nonce: String? = nil) {
        self.name = name
        self.id = id
        self.token = token
        self.appVersion = appVersion
        self.platform = platform
        self.capabilities = capabilities
        self.nonce = nonce
    }

    /// `false` for any capability the receiver did not name — including every
    /// capability, when it named none (i.e. an older receiver).
    public func supports(_ capability: Capability) -> Bool {
        capabilities?.contains(capability) ?? false
    }

    /// The platform, normalized, defaulting to `"macos"` for older senders.
    public var resolvedPlatform: String { platform ?? "macos" }

    private enum CodingKeys: String, CodingKey {
        case name, id, token, appVersion, platform, capabilities, nonce
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decode(String.self, forKey: .id)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        // Absent for older Macs — stay nil so `resolvedPlatform` reads macos.
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        // Absent from every receiver built before peer auth → nil → the phone
        // admits it as a legacy (unauthenticated) session.
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        // Absent for every Mac before 1.1 → nil → `supports` is false for
        // everything, which is exactly 1.0's behaviour.
        //
        // Decoded as [String] and then filtered, NOT as [Capability]: a
        // receiver newer than this phone may advertise abilities it has
        // never heard of, and one unknown raw value must not fail the
        // handshake and cost the user their connection.
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)?
            .compactMap(Capability.init(rawValue:))
    }
}

/// iPhone → receiver: the phone's identity handshake, sent as the FIRST
/// frame on a phone-initiated TCP connection (kind `0x27`).
///
/// The mirror image of `IBClientHello`: on a Mac-initiated connection the
/// receiver dials and introduces itself, but when the phone initiates there is
/// no inbound connection for the receiver to read a `clientHello` from. This
/// frame lets the receiver learn the phone's stable `phoneId` and the computer
/// the phone intends to reach, so it can look up the pairing token and answer
/// the knock.
public struct IBPhoneHello: Codable, Sendable, Equatable {
    /// Stable per-phone UUID, persisted across launches. The receiver keys its
    /// pairing allow-list off this.
    public let phoneId: String
    public let phoneName: String
    /// The `IBClientHello.id` of the computer the phone wants to reach.
    public let targetPcId: String
    public let appVersion: String
    /// Optional, base64 32 bytes. Used for de-duplication / future extension,
    /// **not** part of authentication.
    ///
    /// ADDITIVE + OPTIONAL: absent from a minimal sender, and the custom
    /// decoder below treats absence as nil rather than failing.
    public let nonce: String?
    /// What the phone can do, declared up front.
    ///
    /// ADDITIVE + OPTIONAL. Decoded as `[String]` and then filtered, NOT as
    /// `[Capability]`: a phone newer than this build may name abilities it has
    /// never heard of, and one unknown raw value must not fail the handshake —
    /// same reasoning as `IBClientHello.Capability`.
    public let capabilities: [Capability]?

    /// Declared abilities. Raw values, because an unknown string from a newer
    /// peer must decode rather than fail the whole handshake.
    public enum Capability: String, Codable, Sendable, Equatable {
        /// The phone can initiate the TCP connection itself (knock).
        case phoneInitiated
        /// The phone participates in the challenge-response identity exchange.
        case peerAuth
        /// The phone answers latency probes.
        case latencyProbe
    }

    public init(phoneId: String, phoneName: String, targetPcId: String,
                appVersion: String, nonce: String? = nil,
                capabilities: [Capability]? = nil) {
        self.phoneId = phoneId
        self.phoneName = phoneName
        self.targetPcId = targetPcId
        self.appVersion = appVersion
        self.nonce = nonce
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case phoneId, phoneName, targetPcId, appVersion, nonce, capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneId = try c.decode(String.self, forKey: .phoneId)
        phoneName = try c.decode(String.self, forKey: .phoneName)
        targetPcId = try c.decode(String.self, forKey: .targetPcId)
        // Absent from a minimal/older sender — default rather than fail.
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "0"
        // Absent means nil, not error (forward compatibility).
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        // Decoded as [String] then filtered so an unknown capability from a
        // newer phone does not cost the user their connection.
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)?
            .compactMap(Capability.init(rawValue:))
    }
}

/// iPhone → Mac: the ownership decision for a `clientHello`
/// (kind `0x0B`).
public enum IBSessionReplyResult: String, Codable, Sendable {
    /// This Mac now owns the session.
    case accepted
    /// The iPhone is showing an approval prompt; wait (do not retry).
    case pending
    /// Another Mac already owns the session.
    case busy
    /// The request was explicitly denied.
    case denied
    /// The user tapped Disconnect for this computer on the iPhone. It must not
    /// be auto-accepted on its next dial (that is what made Disconnect look
    /// broken), but it is not "denied" either — the user just wants it off for
    /// now, and picking it again is the way back.
    case off
}

public struct IBSessionReply: Codable, Sendable, Equatable {
    public let result: IBSessionReplyResult
    /// Present for `.busy` — the human name of the Mac that owns it.
    public let ownerName: String?
    /// Present for `.accepted` — the pairing token to persist.
    public let token: String?
    /// The phone's half of the identity challenge, base64.
    ///
    /// ADDITIVE. Absent from every phone built before this exchange, and absence
    /// means "this session is not authenticated" — not "skip the check".
    public let nonce: String?
    /// HMAC-SHA256 the phone computed over both nonces and this receiver's id,
    /// keyed by the pairing token. Absent means the phone cannot do this.
    public let mac: String?
    /// What the phone says it can do, so the receiver knows whether the MAC it is
    /// about to demand is a reasonable thing to expect.
    ///
    /// Strings rather than an enum, for the same reason `IBClientHello` uses
    /// them: a phone newer than this build may name abilities that do not exist
    /// here, and one unknown word must not fail the handshake.
    public let capabilities: [String]?

    public init(result: IBSessionReplyResult, ownerName: String? = nil, token: String? = nil,
                nonce: String? = nil, mac: String? = nil, capabilities: [String]? = nil) {
        self.result = result
        self.ownerName = ownerName
        self.token = token
        self.nonce = nonce
        self.mac = mac
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case result, ownerName, token, nonce, mac, capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(IBSessionReplyResult.self, forKey: .result)
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        // All three default to nil for a phone built before peer auth — that is
        // the legacy branch, not a decode failure.
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)
    }
}

/// Receiver → iPhone: this machine's answer to the phone's half of the
/// challenge (kind `0x26`).
///
/// Sent only after a `sessionReply` that carried a MAC. Its arrival is what lets
/// the phone admit a computer it has already paired with — the proof *replaces*
/// the human tap for that reconnect.
///
/// The phone must never accept a bare `clientHello` as evidence of anything.
/// Presenting a token is not proof of holding it: anyone on the same network can
/// read the same bytes.
public struct IBClientProof: Codable, Sendable, Equatable {
    public let mac: String

    public init(mac: String) {
        self.mac = mac
    }
}

/// One switchable Mac application, surfaced on the iPhone's app
/// switcher. `id` is the bundle identifier, or `pid:<n>` for apps
/// without one (rare on macOS, but possible for helpers).
public struct IBAppInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let pid: Int32
    public let isActive: Bool
    /// 128 px PNG of the app's icon. Only populated when the iPhone
    /// explicitly asks (`.appListRequest`); background refreshes omit it
    /// and the iPhone keeps its own cache, so switching apps stays cheap.
    public let iconPNG: Data?

    public init(id: String, name: String, pid: Int32, isActive: Bool, iconPNG: Data? = nil) {
        self.id = id
        self.name = name
        self.pid = pid
        self.isActive = isActive
        self.iconPNG = iconPNG
    }
}

/// Mac → iPhone: the current list of running regular apps (kind 0x0C).
public struct IBAppList: Codable, Sendable, Equatable {
    public let apps: [IBAppInfo]
    public init(apps: [IBAppInfo]) { self.apps = apps }
}

/// iPhone → Mac: ask for a fresh app list (kind 0x0D).
public struct IBAppListRequest: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - Installed-app launcher (Mac/Windows → iPhone)

/// One launch-able application the receiver can open on demand.
/// `id` is exactly what `IBSystemCommand.launchApp` expects as its
/// argument: the bundle id on the Mac, the `.lnk` path on Windows.
public struct IBInstalledApp: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The app's icon, so the launcher can render a Dock-style grid of real
    /// icons. Nil when the receiver has none.
    ///
    /// **PNG, and it has to stay PNG.** The obvious optimisation — JPEG, 12×
    /// smaller — was tried and reverted: JPEG has no alpha channel, and a
    /// macOS app icon is a *squircle* with transparent corners, so the
    /// encoder fills them with opaque white and the phone renders a white
    /// square behind every tile. The size was won back on the other axis
    /// instead (see `InstalledAppsCatalog`): draw into an explicit 128 px
    /// bitmap rather than `NSImage.lockFocus`, which was inflating the
    /// backing store to 192 px *and* costing ~94 KB per icon.
    public let iconPNG: Data?

    public init(id: String, name: String, iconPNG: Data? = nil) {
        self.id = id
        self.name = name
        self.iconPNG = iconPNG
    }
}

/// Receiver → iPhone: every launch-able app (kind 0x21), sent once per
/// `installedAppsRequest`.
public struct IBInstalledApps: Codable, Sendable, Equatable {
    public let apps: [IBInstalledApp]
    public init(apps: [IBInstalledApp]) { self.apps = apps }
}

/// iPhone → receiver: ask for the installed-app list (kind 0x20).
public struct IBInstalledAppsRequest: Codable, Sendable, Equatable {
    public init() {}
}

/// iPhone → Mac: bring the identified app to the front (kind 0x0E).
/// `windowTitle`, when set, names the specific window to raise (the app
/// is activated too) so the window picker can bring the tapped window
/// forward rather than just its app.
public struct IBActivateApp: Codable, Sendable, Equatable {
    public let id: String
    public let windowTitle: String?
    /// Correlates the `commandResult` this request should produce.
    ///
    /// Optional in both directions on purpose. A phone that predates
    /// `commandResult` omits it, and a receiver then stays silent — the
    /// phone reads that silence as "too old to confirm" rather than as a
    /// failure. A request without an id is still honoured exactly as
    /// before, so nothing regresses for either peer.
    public let requestId: String?
    public init(id: String, windowTitle: String? = nil, requestId: String? = nil) {
        self.id = id
        self.windowTitle = windowTitle
        self.requestId = requestId
    }
}

/// iPhone → Mac: quit the identified app (kind 0x16). `force` uses
/// `NSRunningApplication.forceTerminate()` (SIGKILL-equivalent), which
/// cannot prompt and will lose unsaved work; the graceful path asks the
/// app to quit like ⌘Q does.
/// Receiver → iPhone: what actually happened to a command (kind 0x23).
///
/// This exists so a tap that did nothing says *why*. Before it, `activateApp`
/// and friends were fire-and-forget: a missing Accessibility grant, a quit
/// app and a vanished window all looked identical from the phone — silence.
/// Naming the reason is the whole value; the phone deliberately does **not**
/// retry, because none of these three is fixed by trying again.
public struct IBCommandResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// The target app is no longer running.
        case appNotRunning
        /// The Accessibility permission the receiver needs is missing.
        case noPermission
        /// The app is running but that window does not exist.
        case noWindow
        case failed
    }
    public let requestId: String
    public let status: Status
    /// Free-form, already-localised on the receiver side where possible.
    public let detail: String?
    public init(requestId: String, status: Status, detail: String? = nil) {
        self.requestId = requestId
        self.status = status
        self.detail = detail
    }
}

public struct IBQuitApp: Codable, Sendable, Equatable {
    public let id: String
    public let force: Bool
    /// See `IBActivateApp.requestId`.
    public let requestId: String?
    public init(id: String, force: Bool = false, requestId: String? = nil) {
        self.id = id
        self.force = force
        self.requestId = requestId
    }
}

/// One switchable Mac window, surfaced on the iPhone's full-screen
/// window picker. `id` is `"<pid>:<windowNumber>"`; `appId` matches
/// `IBAppInfo.id` so the iPhone can look up the app icon it already has.
///
/// When macOS has not granted Screen Recording, the Mac can't read other
/// apps' window titles or pixels, so it degrades to one entry per *app*
/// (`title` empty, no snapshot) — see `IBWindowList.canCapture`.
public struct IBWindowInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let appId: String
    public let appName: String
    public let title: String
    public let isActive: Bool
    /// Window content size in points, used to lay out the card (and its
    /// icon placeholder) at the right aspect before the snapshot arrives.
    public let width: Double
    public let height: Double
    /// Downsampled JPEG of the window, present only when the Mac is
    /// allowed to capture and this is a real (not app-level) entry.
    public let snapshotJPEG: Data?

    public init(id: String,
                appId: String,
                appName: String,
                title: String,
                isActive: Bool,
                width: Double = 0,
                height: Double = 0,
                snapshotJPEG: Data? = nil) {
        self.id = id
        self.appId = appId
        self.appName = appName
        self.title = title
        self.isActive = isActive
        self.width = width
        self.height = height
        self.snapshotJPEG = snapshotJPEG
    }
}

/// Mac → iPhone: the current window list (kind 0x18). `canCapture` is
/// false when Screen Recording is not granted, in which case `windows`
/// holds one app-level entry per running app instead of real windows.
public struct IBWindowList: Codable, Sendable, Equatable {
    public let windows: [IBWindowInfo]
    public let canCapture: Bool
    public init(windows: [IBWindowInfo], canCapture: Bool) {
        self.windows = windows
        self.canCapture = canCapture
    }
}

/// iPhone → Mac: ask for a fresh window list (kind 0x17).
public struct IBWindowListRequest: Codable, Sendable, Equatable {
    public init() {}
}

// MARK: - File transfer (iPhone → Mac)

/// iPhone → Mac: begin a file transfer (kind 0x0F). Followed by raw
/// `fileChunk` frames and a `fileComplete`.
public struct IBFileOffer: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Int64
    public init(id: String = UUID().uuidString, name: String, size: Int64) {
        self.id = id
        self.name = name
        self.size = size
    }
}

/// iPhone → Mac: the transfer finished (kind 0x11).
public struct IBFileComplete: Codable, Sendable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}

public enum IBFileAckStatus: String, Codable, Sendable {
    case progress
    case saved
    case error
}

/// Mac → iPhone: transfer feedback (kind 0x12).
public struct IBFileAck: Codable, Sendable, Equatable {
    public let id: String
    public let status: IBFileAckStatus
    public let receivedBytes: Int64
    /// Absolute path on the Mac once saved.
    public let path: String?
    public init(id: String, status: IBFileAckStatus, receivedBytes: Int64, path: String? = nil) {
        self.id = id
        self.status = status
        self.receivedBytes = receivedBytes
        self.path = path
    }
}

// MARK: - Clipboard

/// Either direction: replace the peer's clipboard text (kind 0x13).
public struct IBClipboard: Codable, Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

// MARK: - Notification relay

/// Mac → iPhone: one captured Mac notification banner (kind 0x22).
///
/// `app` is the source app's localized display name (the Accessibility
/// API exposes no bundle id), so the Mac-side denylist matches on it.
/// `subtitle` / `body` are empty when the banner has no such text.
public struct IBNotification: Codable, Sendable, Equatable {
    public let app: String        // source app display name (localized)
    public let title: String
    public let subtitle: String
    public let body: String
    /// The notifying app's front window title at capture time, when the Mac
    /// could read it (needs Screen Recording — window *names* are redacted
    /// without it). Optional so a tap can still raise the app without it,
    /// and so an older Mac/iOS build decodes as nil rather than failing.
    public let windowTitle: String?

    public init(app: String, title: String, subtitle: String = "", body: String = "",
                windowTitle: String? = nil) {
        self.app = app
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.windowTitle = windowTitle
    }
}

// MARK: - System command

/// iPhone → Mac: a system-level action on the Mac (volume, brightness,
/// media keys, app/URL launch). Kind 0x19. Lock screen is NOT here —
/// it's a plain ⌃⌘Q KeyEvent chord from the iOS side.
public struct IBSystemCommand: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case volumeUp, volumeDown, volumeMute
        case brightnessUp, brightnessDown
        case mediaPlayPause, mediaNext, mediaPrevious
        case launchApp      // argument = bundle id
        case openURL        // argument = URL string
        /// Reveal the desktop (minimize/hide everything in front of it).
        case showDesktop
    }
    public let command: Command
    public let argument: String?
    /// See `IBActivateApp.requestId`.
    public let requestId: String?
    public init(command: Command, argument: String? = nil, requestId: String? = nil) {
        self.command = command
        self.argument = argument
        self.requestId = requestId
    }
}

// MARK: - App screen mirror (Mac ↔ iPhone)

/// Where the Mac is in serving a screen-mirror request.
public enum IBScreenStatus: String, Codable, Sendable, Equatable {
    /// A window is being streamed.
    case ok
    /// macOS has not granted Screen Recording to the Mac app.
    case permissionDenied
    /// The frontmost app currently has no capturable window.
    case noWindow
}

/// iPhone → Mac: control the screen mirror (kind 0x1D).
public struct IBScreenControl: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case start
        case stop
        /// Pin a specific window (by `IBWindowInfo.id`); nil = follow frontmost app.
        case select
        /// Resume following the Mac's frontmost app (clear a pin).
        case follow
        /// Extend the Mac's desktop with a virtual display and stream THAT
        /// (the phone becomes a real second monitor); `follow` returns to
        /// mirroring an app window.
        case extend
    }
    public let command: Command
    public let windowId: String?
    /// The phone's preferred long-edge pixel cap, so an iPad can ask for a
    /// sharper mirror than an iPhone. nil = let the Mac use its default.
    public let maxPixel: Int?

    public init(command: Command, windowId: String? = nil, maxPixel: Int? = nil) {
        self.command = command
        self.windowId = windowId
        self.maxPixel = maxPixel
    }
}

/// iPhone → Mac: one direct-manipulation input (kind 0x1E).
///
/// `u`/`v` are normalized `0...1` inside the mirrored window's content.
/// iOS computes them from its own zoom/pan state, so the Mac never needs
/// to know the phone's gesture state. `dx`/`dy` are normalized deltas
/// used by `.scroll`.
public struct IBScreenInput: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case click        // tap = absolute left click
        case dragStart    // begin an absolute left drag
        case dragMove     // continue the drag at a new (u,v)
        case dragEnd      // release the left button
        case rightClick   // two-finger tap / long press
        case scroll       // two-finger drag at the view's pan boundary
    }
    public let action: Action
    public let u: Float
    public let v: Float
    public let dx: Float
    public let dy: Float
    public let modifiers: UInt8
    /// 1 = single click, 2 = double (select word), 3 = triple (select
    /// paragraph). Only meaningful for `.click`.
    public let clickCount: Int
    public let timestampMicros: UInt64

    public init(action: Action,
                u: Float = 0, v: Float = 0,
                dx: Float = 0, dy: Float = 0,
                modifiers: UInt8 = 0,
                clickCount: Int = 1,
                timestampMicros: UInt64 = 0) {
        self.action = action
        self.u = u
        self.v = v
        self.dx = dx
        self.dy = dy
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.timestampMicros = timestampMicros
    }
}

/// Mac → iPhone: the current mirror target + geometry (kind 0x1F). Sent
/// on start, on every target change (app switch), and whenever the
/// mirrored window is moved or resized. `originX/Y` + `width/height` are
/// the window's frame in Mac screen points, needed to translate the
/// normalized `(u,v)` back to a global cursor position.
public struct IBScreenInfo: Codable, Sendable, Equatable {
    public let status: IBScreenStatus
    public let windowId: String?
    public let appId: String?
    public let appName: String?
    public let title: String?
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let showsCursor: Bool

    public init(status: IBScreenStatus,
                windowId: String? = nil,
                appId: String? = nil,
                appName: String? = nil,
                title: String? = nil,
                originX: Double = 0,
                originY: Double = 0,
                width: Double = 0,
                height: Double = 0,
                pixelWidth: Int = 0,
                pixelHeight: Int = 0,
                showsCursor: Bool = true) {
        self.status = status
        self.windowId = windowId
        self.appId = appId
        self.appName = appName
        self.title = title
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.showsCursor = showsCursor
    }
}
