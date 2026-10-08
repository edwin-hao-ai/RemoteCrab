import AVFoundation
import Combine
import Darwin
import Foundation
import Network
import UIKit
import VideoToolbox
import RemoteCrabCore
import os

/// The brain of RemoteCrabCapture. Owns the camera, H.264 encoder, and
/// the Bonjour-published TCP listener. Pushes compressed NAL frames
/// out to whichever Mac connected first.
@MainActor
final class CaptureEngine: ObservableObject {

    private static let log = Logger(subsystem: "com.remotecrab", category: "capture")

    /// Unconditional stderr marker for live forensics — visible via
    /// `devicectl device process launch --console` (os_log doesn't
    /// surface there). Also persisted to a pullable file (Forensic).
    nonisolated static func forensic(_ message: String) {
        Forensic.log("[video-forensic] \(message)")
    }

    // Public state surfaced to SwiftUI.
    /// User-installed context suites, merged over the built-ins.
    ///
    /// Owned here rather than in the view so the sheet and anything else
    /// that resolves a profile read the same list, and so a file dropped
    /// into Documents is picked up without an app relaunch.
    let profiles = ContextProfileStore()

    @Published private(set) var isStreaming = false
    /// True once the capture session's first `startRunning()` has
    /// RETURNED. SwiftUI must not create a camera preview before this:
    /// attaching an AVCaptureVideoPreviewLayer while startRunning is in
    /// flight blocks the main thread for the whole (multi-second) start
    /// — measured 9 s on iPhone 14 — and can wedge the layer black
    /// forever.
    @Published private(set) var captureSessionReady = false
    /// The app's ONE camera preview view; the full-screen surface and the
    /// PiP reparent this same instance. A second AVCaptureVideoPreviewLayer
    /// on the session blocks the main thread ~9 s at cold start (camera
    /// daemon serializes preview-client registration) — measured on
    /// iPhone 14 / iOS 26.
    @Published private(set) var previewView: CameraPreview.PreviewView?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var metadata: IBStreamMetadata = .defaultConfig()
    @Published private(set) var lastLatencyMs: Int?
    /// A one-line message the user should see right now. Auto-clears after
    /// a few seconds. Lives here rather than in a view because the most
    /// important hints are raised from send paths deep in the engine, which
    /// is exactly where the failure used to be invisible.
    @Published private(set) var transientHint: String?
    private var hintDismissTask: Task<Void, Never>?

    /// Show a transient hint, re-arming the timer so a second message
    /// extends the first instead of being cut short by its predecessor.
    func showHint(_ text: String) {
        hintDismissTask?.cancel()
        transientHint = text
        hintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.transientHint = nil
        }
    }

    /// Commands waiting for the receiver's `commandResult`.
    private var commandLedger = IBCommandLedger()
    private var commandExpiryTimer: Timer?
    /// app name per request, so a failure can say which app was meant.
    private var commandAppNames: [String: String] = [:]

    /// `true` only when a frame would actually leave the device. Commands
    /// the user is watching (switch / quit / launch) check this so a dead
    /// link says so instead of silently eating the tap.
    private var canReachMac: Bool { broadcaster?.isReady ?? false }

    // Multi-Mac pairing surface for the UI.
    /// Every Mac the user has approved (settings → Paired Macs).
    @Published private(set) var pairedMacs: [PairedMac] = []
    /// Name of a Mac waiting for the user's approval, if any.
    @Published private(set) var pendingMacName: String?
    /// The Mac the user picked in the Mac picker — it takes over on its
    /// next connect while others are answered "busy".
    @Published private(set) var preferredMac: PairedMac?
    var currentComputerId: String? { pairingStore.currentId }
    var currentComputerName: String? { pairingStore.current?.name }
    /// Set for one refresh when a switch stops holding the door, so the picker
    /// can say so instead of having its banner silently disappear.
    @Published private(set) var preferredGaveUp: PairedMac?
    /// Auto-clears `preferredGaveUp` so the "gave up" card cannot sit on the
    /// main screen forever when nothing dials.
    private var preferredGaveUpAutoClear: Task<Void, Never>?
    /// Re-evaluates the armed preference once a second while one exists, so the
    /// "switching to X…" banner reaches its grace boundary and self-expires even
    /// when no computer dials. Without it the banner was only re-evaluated by
    /// incoming events (a `clientHello`, an outcome), so switching to a computer
    /// that never arrived left "switching to X…" on screen forever.
    private var preferenceRefreshTimer: Timer?
    /// Name of the Mac currently owning the session, if any.
    @Published private(set) var connectedMacName: String?
    /// Stable id of the owning Mac (matches `PairedMac.id`).
    @Published private(set) var connectedMacId: String?
    /// Every computer seen on the network — paired or not. Lets the Mac
    /// picker offer a brand-new Windows PC the user has never approved.
    @Published private(set) var seenComputers: [SeenComputer] = []
    /// Which OS owns the session right now: `"macos"` / `"windows"` /
    /// `"linux"`. Drives the platform-aware keyboard (⌘ vs Ctrl, and the
    /// shortcut bar). Defaults to `"macos"` for older senders.
    @Published private(set) var connectedPlatform: String = "macos"
    /// True when the connected computer is Windows — i.e. the keyboard
    /// surface must show Ctrl/Alt/Shift and Windows shortcut chords.
    var connectedIsWindows: Bool { connectedPlatform.lowercased() == "windows" }
    /// What the owning receiver declared it can do, from its `clientHello`.
    /// Empty for a receiver built before capability negotiation. Drives the
    /// extended-display row: the Mac has always been able to extend, a Windows
    /// receiver only once its IddCx driver is installed, and the phone must not
    /// offer a button that cannot do anything (see `ContentView`).
    @Published private(set) var peerCapabilities: [IBClientHello.Capability] = []
    /// Whether the receiver can turn this phone into an extra display. The Mac
    /// has always done this; a Windows receiver says so only when its driver is
    /// present. Callers keep the platform fallback for a legacy Mac, which
    /// predates the capability but could extend all the same.
    var peerSupportsExtendedDisplay: Bool {
        peerCapabilities.contains(.extendedDisplay)
    }
    /// The peer as the shared package models it. The context sheet needs
    /// this (not a Bool) because a whole action *set* differs per platform,
    /// not just a few labels.
    var peerPlatform: IBModifierBar.PeerPlatform { IBModifierBar.PeerPlatform(connectedPlatform) }
    /// Everything we know about *which computer is on the other end*: its
    /// running apps, its windows, whether it can capture them, and what it
    /// can launch.
    ///
    /// One value with one `clear()`, because these four lists each arrive as
    /// their own frame from whoever owns the session and each used to
    /// outlive that owner. `clearOwner` reset eighteen fields and none of
    /// these, so after Mac → Windows the context sheet still named the Mac's
    /// frontmost app — `访达` on a Chinese macOS — and the launcher offered
    /// the Mac's bundle ids. `PeerIdentity` makes that unrepresentable:
    /// nothing is installed, so nothing is named.
    @Published private(set) var peer = PeerIdentity()
    /// Frontmost app on the connected computer, from the latest `appList`.
    var frontmostMacApp: IBAppInfo? { peer.frontmostApp }

    /// Presents the context-shortcut sheet (observed by ContentView).
    @Published var showContextSheet = false
    /// Decoded app icons keyed by app id. Merged from `appList` frames
    /// that carry `iconPNG`; kept across refreshes because background
    /// publishes omit icons (only an explicit switcher request fetches
    /// them).
    @Published private(set) var macAppIcons: [String: UIImage] = [:]
    /// Decoded window snapshots keyed by `IBWindowInfo.id`. Kept across
    /// refreshes so a background refresh without pixels doesn't blank the
    /// cards. Cleared with the identity — an image of a window belonging to
    /// a computer that left is worse than a placeholder.
    @Published private(set) var macWindowSnapshots: [String: UIImage] = [:]
    /// Fixed listening port (for manual "connect by IP" when Bonjour is
    /// blocked) + this device's WiFi address, shown in the connection sheet.
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var localAddress: String?
    /// 0…1 while sending a file to the Mac; nil when idle.
    @Published private(set) var fileTransferProgress: Double?
    /// Latest transfer ack from the Mac.
    @Published private(set) var lastFileAck: IBFileAck?

    /// In-app inbox for notifications relayed from the Mac. `@Observable`,
    /// so SwiftUI tracks it directly even though this engine is an
    /// `ObservableObject`.
    let notificationStore = NotificationStore()
    private let localNotifier = LocalNotifier()
    /// True once banner authorization has been requested this launch, so
    /// the receive path doesn't spawn a request per notification.
    private var notificationAuthRequested = false

    let captureSession = AVCaptureSession()

    /// Why the link is not up. The `.failed` state used to carry no reason,
    /// so a camera that refused to start and a Wi-Fi that dropped both
    /// produced the same sentence — "Connection to Mac lost. Reconnecting…" —
    /// which is not only wrong for the former, it tells the user to do
    /// something (wait) that will never help.
    enum FailureReason: Equatable {
        /// The capture session could not start (camera in use, denied, or an
        /// unsupported preset). Nothing to do with the Mac.
        case captureStart
        /// The Bonjour listener could not start or died. On iOS this is
        /// almost always the local-network permission.
        case network
        /// An established link went away. The Mac is reconnecting on its own.
        case linkLost
    }

    @Published private(set) var failureReason: FailureReason?

    enum ConnectionState: Equatable {
        case idle
        case starting
        case connected
        case failed

        /// Short label for forensic markers. The state was previously only
        /// observable by looking at the UI, which is how a stale
        /// `.connected` over a dropped link survived for so long.
        var debugName: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .connected: return "connected"
            case .failed: return "failed"
            }
        }
    }

    // MARK: - Private state

    private var encoder = H264Encoder()
    private var listener: NWListener?
    /// Discovers computers announcing `_remotecrab-computer._tcp`, so the picker
    /// can show which are online right now. Independent of the listener/session.
    private var computerBrowser: NWBrowser?
    /// Computers currently announcing themselves, freshest browse snapshot.
    @Published private(set) var onlineComputers: [ComputerPresence] = []
    /// id → the Bonjour endpoint each online computer announced, so a tap can
    /// knock it (dial once) instead of waiting for its retry poll.
    private var computerEndpoints: [String: NWEndpoint] = [:]
    /// The video data output, kept so rotation changes can re-point the
    /// sample-buffer delegate at a rebuilt encoder and set the capture
    /// connection's rotation angle.
    private var videoOutput: AVCaptureVideoDataOutput?
    /// The active video input, kept so a front/back switch can swap it.
    private var videoInput: AVCaptureDeviceInput?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    /// Current video configuration, re-applied (with swapped dims) when
    /// the device rotates between portrait and landscape.
    private var currentResolution = "1080p"
    private var currentFps = 30
    /// Rotation angle currently applied to the capture connection.
    /// 0 = sensor-native landscape; 90 = upright portrait.
    private var currentRotationAngle: CGFloat = 0
    /// Whether the encoder is configured for portrait (swapped) dims.
    private var encoderIsPortrait = false
    private var orientationObserver: NSObjectProtocol?
    /// The granted owner connection. Only this connection streams and
    /// may send `featureControl`; candidates live in `candidate` until
    /// the pairing handshake admits them.
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.remotecrab.encoder")
    private var didConfigure = false

    // MARK: - Multi-Mac handshake state

    private var ownerMac: PairedMac?
    /// Last time any frame arrived from the owner Mac. The Mac pings
    /// every 2 s, so sustained silence means the link is dead — and a
    /// dead-but-still-"ready" socket must not keep answering other Macs
    /// `busy` forever.
    private var lastInboundAt = Date()
    /// Our own latency probes, plus the window the results feed. The phone
    /// used to only echo the Mac's pings, which measures nothing — a ping
    /// carries the *sender's* clock, so whoever echoes cannot compute a
    /// round trip. Now that the receiver echoes probes it didn't originate
    /// (`IBPingProbe`), the phone initiates too and `lastLatencyMs` finally
    /// has a real value.
    private var latencyProbe = IBPingProbe()
    private var latencyTracker = IBLatencyTracker()
    private var latencyProbeTimer: Timer?
    /// Flips to true the first time a probe comes back, which is also how we
    /// learn the receiver is new enough to echo. An older one never answers
    /// and the latency hint simply never appears.
    private var latencyMeasured = false
    /// Whether the "slow connection" hint is currently showing — the edge
    /// detector for `updateLatencyHint()`.
    private var latencyHintShown = false
    /// Set once the `REMOTECRAB_E2E_LINK_LOSS` script has run — see its
    /// call site in `grant()` for why it must not re-arm on reconnect.
    private var e2eLinkLossFired = false
    /// Watchdog that releases a silent owner (see `lastInboundAt`).
    private var ownerWatchdog: Timer?
    /// Connection currently awaiting a `clientHello` (not yet granted).
    private var candidate: NWConnection?
    private var candidateParser: IBWire.Parser?
    /// Connection whose `clientHello` is waiting on the user's approval.
    ///
    /// The three pending fields and `pendingSince` are written **only** by
    /// `setPending` / `clearPending`. They used to be assigned inline at seven
    /// sites, which is how a slot outlived the connection holding it: nothing
    /// tied the timestamp to the connection, so there was nothing to expire and
    /// nothing to assert.
    private var pendingConnection: NWConnection?
    private var pendingHello: IBClientHello?
    private var pendingSince: Date?
    private var pendingWatchdog: Timer?
    /// A computer that already holds this phone's token, mid identity challenge.
    ///
    /// Distinct from the user-approval slot above on purpose: the challenge is
    /// proven by mathematics, not by a human tapping Allow, so it must never put
    /// an approval card on screen. See `PeerAuth`.
    private struct PendingChallenge {
        let connection: NWConnection
        let hello: IBClientHello
        let mac: PairedMac
        /// `client_mac` we expect back inside the receiver's `clientProof`.
        let expectedClientMac: String
        /// The handshake token this challenge belongs to, so a superseded
        /// connection cannot complete someone else's challenge.
        let handshakeToken: UUID
        var timeout: Task<Void, Never>?
    }
    private var pendingChallenge: PendingChallenge?
    /// Identifies the in-flight candidate read so late callbacks from a
    /// superseded connection can't admit the wrong Mac.
    private var handshakeToken: UUID?
    private var handshakeTask: Task<Void, Never>?

    let pairingStore = MacPairingStore()

    /// Shared broadcaster for touch / key / audio events. Created when
    /// a Mac connects and torn down when the connection drops.
    private(set) var broadcaster: IBEventBroadcaster?

    private(set) var audioEncoder: MicrophoneEncoder?

    /// Plays the computer's audio on this phone's speaker (wire kind 0x24).
    /// The first playback code in this app: everything else that made sound
    /// was `BackgroundKeepAlive`, which is deliberately silent.
    private var speakerPlayer = SpeakerPlayer()
    private var speakerTickTask: Task<Void, Never>?
    private var speakerProgressTick = 0

    /// Remembered across launches, like the camera and NOT like the mic.
    /// The microphone deliberately does not persist (restoring `micOn`
    /// would start recording the moment the app launches, which is a
    /// privacy surprise); the speaker only starts the Mac sending audio, and
    /// still requires a live session, so restoring it is a convenience with
    /// no surprise attached.
    private static let speakerHabitKey = "remotecrab.ios.speakerOn"
    /// Why the speaker is not playing, when it should be. Surfaced because a
    /// control that fails silently is worse than one that is not there.
    @Published private(set) var speakerStatus: String?

    /// Single source of truth for capability state. Bound by the UI
    /// and mutated by remote FeatureControl frames alike.
    let features = FeatureStore()

    // MARK: - App screen mirror

    /// The app's single screen-mirror display view. Owned by the engine so
    /// SwiftUI can reparent it without recreating the
    /// `AVSampleBufferDisplayLayer` (same shared-view pattern as the
    /// camera preview).
    let screenDisplayView = ScreenDisplayUIView(frame: .zero)

    /// Live mirror target geometry, pushed by the Mac (`screenInfo`, 0x1F).
    @Published private(set) var screenInfo: IBScreenInfo?
    /// Whether `screenControl.start` has been sent for the current link.
    @Published private(set) var screenActive = false
    /// The Mac window the user pinned from the mirror's window chip; nil
    /// means the Mac follows its own frontmost app.
    @Published private(set) var screenPinnedWindowId: String?
    /// Set by `ContentView` while the app is backgrounded on the mirror
    /// surface, so the last mirrored frame is covered instead of leaking
    /// into the app-switcher snapshot.
    @Published var privacyCover = false

    /// The phone's preferred long-edge pixel cap for the mirror: an iPad
    /// has the screen estate (and bandwidth) for a sharper stream.
    var preferredMaxPixel: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 2560 : 1920
    }

    /// Real Mac windows offered by the mirror's window chip: the current
    /// app's windows when known (non-empty), otherwise every real window.
    /// App-level placeholder entries (no `:` in the id) are dropped, and
    /// the active window sorts first.
    var screenWindows: [IBWindowInfo] {
        let real = peer.windows.filter { $0.id.contains(":") }
        let sameApp = screenInfo?.appId.map { appId in real.filter { $0.appId == appId } } ?? []
        let pool = sameApp.isEmpty ? real : sameApp
        return pool.sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
    }

    /// Decodes the Mac→iPhone mirror stream into the display layer. Built
    /// lazily so the decoder's `onSampleBuffer` can capture `self`.
    lazy var screenDecoder: ScreenDecoder = {
        let decoder = ScreenDecoder()
        // `onSampleBuffer` fires on the decoder's serial queue. Enqueue to
        // the display layer from there instead of hopping to the main actor
        // ~24×/s — that main-thread churn competed with voice dictation and
        // made typing laggy / drop characters. The layer isn't Sendable, so
        // box it (the decoder queue is serial, so access stays serialized).
        let layerBox = ScreenSendableBox(value: screenDisplayView.displayLayer)
        decoder.onSampleBuffer = { sample in
            let layer = layerBox.value
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
        return decoder
    }()

    /// Remembers the user's camera choice across launches (a fresh
    /// install still defaults to off). Written ONLY by explicit toggles
    /// via `setCameraEnabled` — automatic offs (backgrounding, disconnect,
    /// e2e) go through `features.set` and never overwrite the habit.
    ///
    /// Deliberately camera-only: restoring `micOn` would start recording
    /// the moment the app launches, which is a privacy surprise.
    private static let cameraHabitKey = "remotecrab.ios.cameraOn"

    /// User-initiated camera toggle: apply it AND remember it.
    func setCameraEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.cameraHabitKey)
        features.set(feature: .camera, enabled: enabled)
    }

    /// Restore the remembered camera choice once at startup. Called
    /// before any connection; first launch keeps the off default.
    private func restoreStreamHabits() {
        if UserDefaults.standard.bool(forKey: Self.cameraHabitKey) {
            features.set(feature: .camera, enabled: true)
        }
    }

    private let parser = IBWire.Parser()

    // MARK: - Lifecycle

    /// Request permissions and start the AVCaptureSession. Called from
    /// the SwiftUI `.task` modifier on the root view.
    func startIfNeeded() async {
        guard !didConfigure else { return }
        didConfigure = true
        Forensic.reset()
        Forensic.MainStallMonitor.start()
        Forensic.SelfShot.install()
        installNotificationTapRouting()
        Self.forensic("startIfNeeded begin")
        Forensic.log("[e2e] startIfNeeded begin")
        // E2E: measures whether the audio session can hand over between the
        // mic's `.record` and a speaker's `.playback` — the question that
        // decides if "use the iPhone as the computer's speaker" is possible.
        // Inert unless REMOTECRAB_E2E_AUDIOSESSION=1.
        AudioSessionProbe.runIfRequested()
        // E2E: "use the iPhone as the speaker".
        //
        // Fired at LAUNCH rather than after the session is accepted, on
        // purpose: the real run asserts from the Mac's receiver log, and a
        // phone-side smoke test (does the mode switch, the session claim and
        // the player survive being turned on) needs no Mac at all. Anchoring
        // it to the connection meant a simulator could never exercise the
        // path, which is exactly where a crash in it would be cheapest to
        // find.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SPEAKER"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                self.setAudioMode(.speaker)
                Forensic.log("[e2e] speaker mode requested")
            }
        }

        features.onChange = { [weak self] snapshot in
            self?.handleFeaturesChanged(snapshot)
        }
        restoreStreamHabits()
        refreshPairedMacs()

        await requestPermissions()
        Self.forensic("stage: permissions done")

        // Configure portrait/landscape UP FRONT: rebuilding the encoder
        // right after a cold session start (orientation observer firing
        // into the in-flight startRunning) visibly froze the launch UI.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let initialAngle = Self.rotationAngle(for: UIDevice.current.orientation) ?? 90
        currentRotationAngle = initialAngle
        encoderIsPortrait = initialAngle == 90 || initialAngle == 270

        let savedResolution = UserDefaults.standard.string(forKey: "remotecrab.ios.resolution") ?? "1080p"
        let savedFps = UserDefaults.standard.integer(forKey: "remotecrab.ios.frameRate")
        currentResolution = savedResolution
        currentFps = savedFps == 0 ? 30 : savedFps

        let dims = videoDims(resolution: currentResolution, portrait: encoderIsPortrait)
        do {
            // The encoder must exist BEFORE the session is configured:
            // configuration wires `videoOutput.setSampleBufferDelegate(encoder)`
            // — passing nil silently drops every frame.
            let newEncoder = H264Encoder(width: Int32(dims.width), height: Int32(dims.height),
                                         fps: currentFps,
                                         bitrate: VideoEncodingPolicy.bitrate(width: dims.width, height: dims.height, fps: currentFps))
            encoder = newEncoder
            // commitConfiguration + addInput block for several hundred ms —
            // run the whole configuration on the capture queue so the
            // launch UI never stalls. The box hops the non-Sendable AV
            // objects across the continuation.
            let outcome = await withCheckedContinuation { continuation in
                let position = currentCameraPosition
                queue.async { [captureSession, queue] in
                    let outcome: ConfigureOutcome
                    do {
                        let (input, output) = try Self.configureCaptureSession(
                            captureSession, preset: dims.preset,
                            rotationAngle: initialAngle, position: position,
                            delegate: newEncoder, delegateQueue: queue)
                        outcome = ConfigureOutcome(input: input, output: output, error: nil)
                    } catch {
                        outcome = ConfigureOutcome(input: nil, output: nil, error: error)
                    }
                    continuation.resume(returning: outcome)
                }
            }
            if let error = outcome.error { throw error }
            Self.forensic("stage: session configured")
            videoInput = outcome.input
            videoOutput = outcome.output
            metadata = IBStreamMetadata(deviceName: UIDevice.current.name,
                                        width: dims.width, height: dims.height,
                                        fps: currentFps,
                                        bitrateBps: VideoEncodingPolicy.bitrate(width: dims.width, height: dims.height, fps: currentFps))
            observeCaptureInterruptions()
            observeDeviceOrientation()
            try await newEncoder.start { [weak self] frame in
                Task { @MainActor in
                    self?.handleEncodedFrame(frame)
                }
            }
            // startRunning blocks for ~1 s — never on the main thread.
            queue.async { [captureSession, weak self] in
                captureSession.startRunning()
                Self.forensic("stage: startRunning returned")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The session is running now, so attaching the single
                    // shared preview layer is fast and cannot wedge.
                    let view = CameraPreview.PreviewView(label: "shared")
                    view.attach(to: self.captureSession)
                    self.previewView = view
                    self.captureSessionReady = true
                }
            }
        } catch {
            Self.log.error("capture start failed: \(error, privacy: .public)")
            connectionState = .failed
            failureReason = .captureStart
            didConfigure = false
        }

        // Advertise + accept the Mac as soon as the app is ready — NOT
        // tied to the camera. Trackpad, keyboard and voice work without
        // ever turning the camera on; the camera is just another toggle.
        await startStreaming()
        Self.forensic("stage: startIfNeeded done")
    }

    func toggleStreaming() async {
        if isStreaming {
            stopStreaming()
        } else {
            await startStreaming()
        }
    }

    /// V0.2 — receive touch events from the SwiftUI trackpad view
    /// and forward them over the wire.
    func sendTouch(_ event: TouchEvent) {
        guard features.trackpadOn else { return }
        broadcaster?.send(event)
    }

    /// V0.2 — receive key events from the SwiftUI keyboard view and
    /// forward them over the wire.
    func sendKey(_ event: KeyEvent) {
        guard features.keyboardOn else { return }
        broadcaster?.send(event)
    }

    /// Context-sheet system command (volume / brightness / media / launch).
    /// Not gated on a feature toggle: the console is always available.
    func sendSystemCommand(_ command: IBSystemCommand) {
        broadcaster?.send(command)
    }

    /// Voice dictation. Ships as `.text` KeyEvents over the same wire
    /// channel as the keyboard, but is deliberately NOT gated on
    /// `keyboardOn` — voice is its own feature and must work from any
    /// surface.
    ///
    /// Interim results are typed as they arrive (word-by-word) so the Mac
    /// feels live. Two rules keep it lossless even though the on-device
    /// recognizer rewrites text mid-utterance:
    ///
    ///  * **Live pass is append-only.** We type the finalized prefix plus
    ///    the part of the live segment that has been stable for one update;
    ///    we never delete mid-sentence, so revision churn can't drop chars.
    ///  * **One exact reconcile per segment boundary** (and at release).
    ///    When a segment finalizes — including the on-device recognizer
    ///    discarding its transcript on a pause — we tail-sync the Mac's
    ///    insertion point to the finalized text (backspace+retype the
    ///    volatile tail there and only there).
    ///
    /// Also doubles as a tiny voice-command surface: "open X" / "切换到 X"
    /// activates a running Mac app, "改写…" transforms the Mac's selection.
    private var voiceTypedText = ""
    /// Live-segment transcript from the previous update (stability check).
    private var voiceLastLive = ""
    /// Committed prefix length from the previous update (boundary detect).
    private var voiceLastCommitted = 0

    /// Reset the trackers at the start of every hold, so a session that
    /// ended without a clean final (e.g. interrupted) can't make the next
    /// hold backspace the previous one's text.
    func beginVoiceSession() {
        voiceTypedText = ""
        voiceLastLive = ""
        voiceLastCommitted = 0
    }

    /// Interim transcription. `committed` is the length of the FINALIZED
    /// prefix of `full` (segments the recognizer has closed).
    func updateVoiceText(_ full: String, committed: Int) {
        // Don't type live while the utterance looks like a command;
        // wait for the final so the command words never hit the Mac.
        guard !looksLikeVoiceCommand(full) else { return }

        let committedText = String(full.prefix(committed))
        let live = String(full.dropFirst(committed))

        // Segment boundary: reconcile exactly to the finalized prefix
        // (bounded tail correction — the volatile tail is at the end).
        let boundary = voiceLastCommitted != committed
        voiceLastCommitted = committed
        if boundary {
            reconcileVoiceText(to: committedText)
            voiceLastLive = ""
        }

        // Live tail: type only what has been stable for one update,
        // append-only. The last (still-revising) partial is deferred.
        let stableLive = Self.commonPrefix(live, voiceLastLive)
        voiceLastLive = live
        let desired = committedText + stableLive
        guard desired.hasPrefix(voiceTypedText) else { return }
        guard desired.count > voiceTypedText.count else { return }
        let add = String(desired.dropFirst(voiceTypedText.count))
        if !add.isEmpty { broadcaster?.send(KeyEvent(action: .text, text: add)) }
        voiceTypedText = desired
    }

    /// Final transcription for the hold.
    func finishVoiceText(_ final: String) {
        defer {
            voiceTypedText = ""
            voiceLastLive = ""
            voiceLastCommitted = 0
        }
        if handleVoiceCommand(final) {
            // Deliberately do NOT erase what the live pass typed: a long
            // dictation that merely starts with a command-like word was
            // being mis-detected here and the whole paragraph got
            // backspaced away. A stray prefix word beats data loss.
            return
        }
        // Type the volatile tail the live pass never typed; also repairs
        // any late rewrite. Final, so a tail-only diff is safe here — but
        // never SHRINK: when the recognizer's final truncates the tail, the
        // live pass already typed more, and reconciling down would delete
        // the user's last characters. A stray extra character beats data
        // loss.
        let target = final.count >= voiceTypedText.count ? final : voiceTypedText
        reconcileVoiceText(to: target)
    }

    /// Tail-only sync of the Mac's insertion point to `desired`.
    private func reconcileVoiceText(to desired: String) {
        guard desired != voiceTypedText else { return }
        for event in TextDiff.tailEvents(from: voiceTypedText, to: desired) {
            broadcaster?.send(event)
        }
        Forensic.log("[voice] reconcile \(voiceTypedText.count)→\(desired.count)")
        voiceTypedText = desired
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        for (ca, cb) in zip(a, b) where ca == cb { result.append(ca) }
        return result
    }

    private func looksLikeVoiceCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["切换到", "打开", "跳转到", "switch to ", "open ", "launch ", "go to ",
                        "改写", "格式化", "变成", "转成", "改成",
                        "rewrite", "reformat", "format", "make it", "make this"]
        return prefixes.contains { t.hasPrefix($0) }
    }

    private func handleVoiceCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // "open X" / "切换到 X" → activate a running Mac app.
        let appPrefixes = ["切换到", "打开", "跳转到", "switch to ", "open ", "launch ", "go to "]
        for prefix in appPrefixes where t.hasPrefix(prefix) {
            let target = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            if let app = peer.apps.first(where: {
                $0.name.lowercased().contains(target) || $0.id.lowercased().contains(target)
            }) {
                Self.log.info("voice command → activate \(app.name, privacy: .public)")
                activateMacApp(id: app.id, appName: app.name)
                return true
            }
        }

        // "改写成大写" / "make this bullet list" → transform the Mac's
        // current selection. Requires an explicit trigger so ordinary
        // dictation that merely contains a keyword isn't hijacked.
        let triggers = ["改写", "格式化", "变成", "转成", "改成",
                        "rewrite", "reformat", "format", "make it", "make this"]
        guard triggers.contains(where: { t.hasPrefix($0) }) else { return false }
        let commands: [(String, IBTextCommand)] = [
            ("全部大写", .uppercase), ("大写", .uppercase), ("uppercase", .uppercase),
            ("小写", .lowercase), ("lowercase", .lowercase),
            ("首字母大写", .capitalize), ("标题", .capitalize),
            ("capitalize", .capitalize), ("title case", .capitalize),
            ("去空格", .trimWhitespace), ("多余空格", .trimWhitespace), ("trim", .trimWhitespace),
            ("去掉换行", .stripNewlines), ("合并成一行", .stripNewlines), ("一行", .stripNewlines),
            ("项目符号", .bulletList), ("变成列表", .bulletList), ("bullet", .bulletList)
        ]
        for (phrase, command) in commands.sorted(by: { $0.0.count > $1.0.count })
        where t.contains(phrase) {
            broadcaster?.send(IBTextCommandMessage(command: command))
            Self.log.info("voice command → transform \(command.rawValue, privacy: .public)")
            return true
        }
        return false
    }

    // MARK: - Clipboard

    /// Send the iPhone clipboard text to the Mac.
    func sendClipboard() {
        let text = UIPasteboard.general.string ?? ""
        guard !text.isEmpty else { return }
        broadcaster?.send(IBClipboard(text: text))
    }

    // MARK: - Relayed Mac notifications

    /// Ask once for permission to surface relayed Mac notifications as
    /// system banners. Idempotent — safe to call on every appearance;
    /// it only presents a prompt while the status is `.notDetermined`.
    ///
    /// Deliberately NOT called from the boot `.task`: the prompt would
    /// suspend that task and block the listener from starting. Call it
    /// in context instead (opening the inbox, first relayed banner).
    func requestNotificationAuthorization() async {
        notificationAuthRequested = true
        _ = await localNotifier.requestAuthorization()
    }

    /// Non-blocking variant for the receive path: ask at most once this
    /// launch, when a relayed notification arrives and the user has not
    /// answered yet. Safe to call for every notification.
    func requestNotificationAuthorizationIfNeeded() {
        guard !notificationAuthRequested else { return }
        Task { @MainActor [weak self] in
            await self?.requestNotificationAuthorization()
        }
    }

    /// Register the tap router. Called once at launch; a tap that cold-started
    /// the app is delivered as soon as the handler exists.
    func installNotificationTapRouting() {
        NotificationTapRouter.shared.setHandler { [weak self] appName, windowTitle in
            Task { @MainActor [weak self] in
                self?.activateRelayedApp(named: appName, windowTitle: windowTitle)
            }
        }
    }

    /// A tap on a relayed notification: switch the Mac to the app (and    /// window) that sent it — the same "tap a notification, land in the app"
    /// behaviour as a local notification.
    ///
    /// Does nothing when that app is no longer running: activating an app the
    /// user quit would be a surprise, and the sender name is the only
    /// identity the banner carries. Logged, so "the tap did nothing" is never
    /// silent. The app name is the *sender*, not notification content, so it
    /// is safe to record (the file is DEBUG/devicectl-only).
    func activateRelayedApp(named appName: String, windowTitle: String?) {
        guard let app = NotificationAppResolver.resolve(name: appName, in: peer.apps) else {
            Forensic.log("[notify] tap: '\(appName)' not running — ignored")
            return
        }
        let hasWindow = !(windowTitle ?? "").isEmpty
        Forensic.log("[notify] tap: activating '\(app.name)' window=\(hasWindow ? "yes" : "no")")
        activateMacApp(id: app.id, windowTitle: windowTitle, appName: app.name)
    }

    /// Screenshot/E2E hook: fill the in-app inbox from a JSON array of
    /// `IBNotification`. Lets the App Store screenshots show a realistic
    /// inbox without a live Mac, while keeping demo content *out* of the
    /// shipping binary — the data comes from the capture script's environment.
    func seedNotifications(json: String) {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([IBNotification].self, from: data) else { return }
        notificationStore.clear()
        // `append` prepends, so the last item ends up at the top of the list.
        for item in items { notificationStore.append(item) }
    }

    // MARK: - App screen mirror

    /// Enter the mirror surface and ask the Mac to start streaming its
    /// frontmost window. Safe to call while disconnected — the surface
    /// shows a "waiting for your computer" placeholder until the Mac
    /// sends `screenInfo`.
    func startScreenMirror() {
        screenPinnedWindowId = nil
        if !features.screenOn {
            features.set(feature: .screen, enabled: true)
        } else if !screenActive {
            // Already on, but the link was re-established without the
            // start frame going out — send it now (with our pixel cap).
            syncScreen()
        }
        features.activeSurface = .screen
    }

    /// Leave the mirror and ask the Mac to stop streaming.
    func stopScreenMirror() {
        screenPinnedWindowId = nil
        if features.screenOn {
            features.set(feature: .screen, enabled: false)
        } else {
            syncScreen()
        }
        screenDecoder.reset()
        screenInfo = nil
        screenDisplayView.displayLayer.flushAndRemoveImage()
        if features.activeSurface == .screen {
            features.activeSurface = .trackpad
        }
    }

    /// Pin the mirror to one specific Mac window (window-chip selection).
    func selectScreenWindow(id: String) {
        screenPinnedWindowId = id
        Forensic.log("[e2e] screen select window \(id)")
        broadcaster?.send(IBScreenControl(command: .select, windowId: id))
    }

    /// Resume following the Mac's frontmost app (clear a pin).
    func followFrontmostScreenWindow() {
        screenPinnedWindowId = nil
        Forensic.log("[e2e] screen follow frontmost")
        broadcaster?.send(IBScreenControl(command: .follow))
    }

    /// Extend the Mac's desktop with a virtual display and mirror THAT —
    /// the phone becomes a real second monitor. `follow` returns to
    /// mirroring an app window.
    func extendToVirtualDisplay() {
        screenPinnedWindowId = nil
        Forensic.log("[e2e] screen extend display")
        broadcaster?.send(IBScreenControl(command: .extend, maxPixel: preferredMaxPixel))
    }

    /// True while the Mac is streaming the **extended** (virtual) display —
    /// a source of its own, parallel to mirroring an app window.
    var isExtendedDisplayOn: Bool { screenInfo?.appId == "extended" }

    /// Top-bar toggle: extend the Mac desktop onto this phone (creating the
    /// virtual display), or drop back to mirroring the frontmost window.
    /// Opening the viewer first when needed, so it works standalone.
    func toggleExtendedDisplay() {
        Forensic.log("[e2e] toggle extended display: on=\(isExtendedDisplayOn) screenOn=\(features.screenOn) connected=\(broadcaster != nil)")
        if isExtendedDisplayOn {
            // Tapping the active source turns the viewer off (symmetric with
            // the mirror toggle) — switching to the OTHER source is what the
            // mirror button does.
            stopScreenMirror()
            return
        }
        if !features.screenOn {
            // Open the mirror viewer (sends screenControl.start); the
            // `.extend` right after switches it to the virtual display.
            features.set(feature: .screen, enabled: true)
        }
        extendToVirtualDisplay()
    }

    func toggleScreenMirror() {
        // Mirror and Extended Display are two SOURCES for the same viewer and
        // are mutually exclusive: tapping the other one switches (and closes
        // the current source), tapping the active one turns it off.
        if isExtendedDisplayOn {
            screenPinnedWindowId = nil
            Forensic.log("[e2e] switch extended → mirror window")
            broadcaster?.send(IBScreenControl(command: .follow))
        } else if features.screenOn {
            stopScreenMirror()
        } else {
            startScreenMirror()
        }
    }

    /// Forward one direct-manipulation input to the Mac.
    func sendScreenInput(_ input: IBScreenInput) {
        guard connection?.state == .ready else { return }
        Forensic.log("[e2e] screen input \(input.action.rawValue) u=\(input.u) v=\(input.v)")
        broadcaster?.send(input)
    }

    func startStreaming() async {
        Forensic.log("[e2e] startStreaming called, isStreaming=\(isStreaming)")
        guard !isStreaming else { return }
        // E2E: deterministic start. These must run BEFORE the listener
        // advertises, or the receiver may dial first, be answered `busy` by a
        // leftover `current`, and stand by for its 60 s safety net — which the
        // e2e window never waits out.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_RELEASE_CURRENT"] == "1" {
            releaseCurrentComputer()
            Forensic.log("[e2e] released current computer at launch")
        }
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_RESET_PAIRING"] == "1" {
            pairingStore.removeAll()
            refreshPairedMacs()
            Forensic.log("[e2e] reset pairing at launch")
        }
        connectionState = .starting
        do {
            try startListener()
            Forensic.log("[e2e] listener started OK")
            startComputerBrowser()
            isStreaming = true
            lastVideoFrameAt = Date()
            hasProducedVideoFrame = false
            startVideoWatchdog()
            // Stay reachable while backgrounded / locked: without this
            // iOS suspends the app, the Bonjour listener goes away, and
            // the Mac can't reconnect until the app is reopened.
            applyKeepAlive()
            UIApplication.shared.isIdleTimerDisabled =
                UserDefaults.standard.bool(forKey: "remotecrab.ios.keepScreenOn")
                || ProcessInfo.processInfo.environment["REMOTECRAB_AUTOSTREAM"] == "1"
        } catch {
            Self.log.error("listener start failed: \(error, privacy: .public)")
            Forensic.log("[e2e] listener start FAILED: \(error)")
            connectionState = .failed
            failureReason = .network
        }
        // E2E: the picker tap cannot be done headlessly (see the fn).
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_PICK_ONLINE"] == "1" {
            runE2EPickOnlineComputer()
        }
    }

    func stopStreaming() {
        BackgroundKeepAlive.shared.stop()
        stopComputerBrowser()
        listener?.cancel()
        listener = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate?.cancel()
        candidate = nil
        candidateParser = nil
        pendingConnection?.cancel()
        clearPending()
        connection?.cancel()
        clearOwner(reason: .disconnected)
        isStreaming = false
        parser.reset()
        stopVideoWatchdog()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// E2E-only: the picker's tap on an online computer needs a human finger,
    /// so this runs the *same* action `ComputerPickerView`'s row tap runs —
    /// pick the first online computer that is not the current one, once
    /// presence has reported it. Proves the 10-07 "pair a new computer" path
    /// (arming `preferred` for a computer the phone has only seen announce
    /// itself, never connected to) end-to-end on a device.
    private func runE2EPickOnlineComputer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let target = self.onlineComputers.first(where: { $0.id != self.currentComputerId })
                else { continue }
                Forensic.log("[e2e] pick online computer id=\(target.id.prefix(8)) name=\(target.name)")
                self.setPreferredComputer(id: target.id)
                Forensic.log("[e2e] pick online resolved=\(self.preferredMac?.id == target.id)")
                return
            }
            Forensic.log("[e2e] pick online: no eligible online computer found")
        }
    }

    // MARK: - Computer presence

    /// Browse `_remotecrab-computer._tcp` so the picker can show which computers
    /// are online. Read-only: we never connect to this service, the computer
    /// still dials us.
    private func startComputerBrowser() {
        guard computerBrowser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // `.bonjourWithTXTRecord`, not `.bonjour`: the plain descriptor returns
        // the service with `.none` metadata, so the id/name/platform TXT never
        // reaches the browse result and every computer looks unknown. Measured
        // on iPhone 14: `results=1 bonjour=0` with `.bonjour`.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: IBServiceType.computer, domain: nil), using: params)
        browser.stateUpdateHandler = { state in
            Forensic.log("[presence] browser state: \(state)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [ComputerPresence] = []
            var endpoints: [String: NWEndpoint] = [:]
            var sawBonjour = 0
            for result in results {
                if case let .bonjour(record) = result.metadata {
                    sawBonjour += 1
                    let id = record.dictionary[IBServiceType.PresenceTXT.id]
                    guard let id, !id.isEmpty else { continue }
                    let name = record.dictionary[IBServiceType.PresenceTXT.name] ?? id
                    let platform = record.dictionary[IBServiceType.PresenceTXT.platform] ?? "macos"
                    found.append(ComputerPresence(id: id, name: name, platform: platform))
                    // Keep the Bonjour endpoint so a tap can knock it (see
                    // `knockComputer`); the SRV record already carries the port.
                    endpoints[id] = result.endpoint
                }
            }
            Forensic.log("[presence] results=\(results.count) bonjour=\(sawBonjour) online=\(found.count)")
            Task { @MainActor [weak self] in
                self?.onlineComputers = found
                self?.computerEndpoints = endpoints
            }
        }
        browser.start(queue: queue)
        computerBrowser = browser
        Self.log.info("browsing \(IBServiceType.computer, privacy: .public)")
    }

    private func stopComputerBrowser() {
        computerBrowser?.cancel()
        computerBrowser = nil
        onlineComputers = []
    }

    /// Called on every return to the foreground (scenePhase == .active).
    /// iOS suspends the Bonjour listener while the app is backgrounded,
    /// so a previously-streaming app comes back with a dead
    /// advertisement and usually a reset TCP link while `isStreaming`
    /// still reads true. Recreate the listener to force the service to
    /// re-register; the Mac side auto-reconnects once we're visible.
    func handleDidBecomeActive() {
        guard isStreaming else { return }
        // The browse is suspended in the background too — refresh it so the
        // picker is not stale the moment the user returns.
        stopComputerBrowser()
        startComputerBrowser()
        if !captureSession.isRunning {
            // Backgrounding interrupts the capture session; audio
            // (separate AVAudioEngine) survives but video stays dead
            // until we explicitly restart.
            Self.log.info("foreground: capture session not running — restarting")
            queue.async { [captureSession] in captureSession.startRunning() }
        }
        let linkAlive = connection?.state == .ready
        Self.log.info("foreground: isStreaming=true linkAlive=\(linkAlive, privacy: .public)")
        guard !linkAlive else { return }
        // If the audio keep-alive is holding the app alive, iOS did NOT
        // suspend the Bonjour listener — so a full stop/start would only tear
        // down a perfectly good listener, and the Mac saw "connection reset by
        // peer" every time the user foregrounded the app (which read as
        // "reconnect almost never works"). Only rebuild when nothing is
        // holding the app: keep-alive off, i.e. the listener really may have
        // been suspended.
        guard !BackgroundKeepAlive.shared.isActive else {
            Self.log.info("foreground: keep-alive holds the listener — not rebuilding")
            return
        }
        Task {
            stopStreaming()
            await startStreaming()
        }
    }

    // MARK: - Capture session interruptions

    /// Backgrounding interrupts the AVCaptureSession (video device
    /// unavailable in background) and a media-services reset can kill
    /// it outright. iOS does NOT guarantee automatic recovery — an
    /// unhandled interruption is why video went silent after every
    /// background round-trip while audio kept flowing.
    private func observeCaptureInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                           object: captureSession, queue: nil) { [weak self] _ in
            Self.log.info("capture interruption ended — ensuring running")
            Self.forensic("interruption ENDED, isRunning=\(self?.captureSession.isRunning ?? false)")
            self?.restartCaptureAfterInterruption()
        }
        center.addObserver(forName: .AVCaptureSessionRuntimeError,
                           object: captureSession, queue: nil) { [weak self] note in
            Self.log.error("capture runtime error: \(note.userInfo ?? [:], privacy: .public)")
            Self.forensic("RUNTIME ERROR: \(note.userInfo ?? [:])")
            self?.restartCaptureIfNeeded()
        }
        center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                           object: captureSession, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            Self.log.info("capture session interrupted")
            Self.forensic("INTERRUPTED reason=\(reason.map(String.init) ?? "nil") userInfo=\(note.userInfo ?? [:])")
        }
    }

    private func restartCaptureIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            Self.forensic("restartCaptureIfNeeded: isRunning=\(self.captureSession.isRunning)")
            guard !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    /// Called when a capture interruption ends. iOS sometimes reports
    /// `isRunning == true` here while the device feed is degraded —
    /// observed on device: after a long background interruption the
    /// session kept "running" but delivered pure-black frames forever
    /// (capture luma probe avg=0, Mac frame probe avg=0), while a
    /// stop/start cycle recovers real pixels. So: always cycle the
    /// session after an interruption, not just when it looks stopped.
    private func restartCaptureAfterInterruption() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                Self.forensic("interruption ended with isRunning=true — forcing stop/start")
                self.captureSession.stopRunning()
            }
            self.captureSession.startRunning()
        }
    }

    /// Last time the encoder produced a frame. Drives the watchdog below.
    private var lastVideoFrameAt = Date()
    /// Whether the encoder has produced at least one frame since the
    /// last (re)start. Until it has, the pipeline is still warming up
    /// and the watchdog must use a long grace period — a cold
    /// `startRunning()` can legitimately take several seconds.
    private var hasProducedVideoFrame = false
    /// Camera on/off on the previous feature snapshot, so the watchdog
    /// gets a fresh grace period when the user re-enables the camera.
    private var wasCameraOn = true
    private var videoWatchdog: DispatchSourceTimer?

    /// AVFoundation has a state where `captureSession.isRunning` is true
    /// but the video output silently stops delivering — an interruption
    /// that `restartCaptureIfNeeded`'s `!isRunning` check can't see.
    /// Symptom: touch and audio keep flowing while video goes black
    /// forever. This watchdog force-restarts the session whenever the
    /// camera should be producing but hasn't for >2.5 s.
    private func startVideoWatchdog() {
        guard videoWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        // The handler must be explicitly @Sendable: a plain closure formed
        // in this @MainActor type inherits MainActor isolation and traps in
        // swift_task_checkIsolated when the timer fires on `queue`
        // (EXC_BREAKPOINT in _dispatch_assert_queue_fail).
        let tick: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.checkVideoHeartbeat() }
        }
        timer.setEventHandler(handler: tick)
        timer.resume()
        videoWatchdog = timer
    }

    private func stopVideoWatchdog() {
        videoWatchdog?.cancel()
        videoWatchdog = nil
    }

    private func checkVideoHeartbeat() {
        guard isStreaming, features.cameraOn else { return }
        guard connection?.state == .ready else { return }
        // Only recover while foregrounded — in the background the camera
        // is unavailable by platform rule and a restart can't succeed.
        guard UIApplication.shared.applicationState == .active else { return }
        // Session still starting (startRunning is async on `queue`) —
        // nothing to recover yet.
        guard captureSession.isRunning else { return }
        let idle = Date().timeIntervalSince(lastVideoFrameAt)
        // Cold start / reconfiguration: the first frame can take many
        // seconds; only use the tight 2.5 s stall threshold once frames
        // have actually flowed.
        let threshold: TimeInterval = hasProducedVideoFrame ? 2.5 : 12
        guard idle > threshold else { return }
        Self.log.error("no video frames for \(Int(idle), privacy: .public)s with camera on — force-restarting capture session")
        Self.forensic("WATCHDOG fired: idle=\(Int(idle))s isRunning=\(captureSession.isRunning) — stop/start")
        lastVideoFrameAt = Date()
        queue.async { [captureSession] in
            captureSession.stopRunning()
            captureSession.startRunning()
        }
    }

    // MARK: - Video reconfiguration

    /// Base (landscape) dims for a resolution name, then swapped when
    /// the phone is held in portrait.
    private func videoDims(resolution: String, portrait: Bool)
        -> (preset: AVCaptureSession.Preset, width: Int, height: Int) {
        let (preset, w, h): (AVCaptureSession.Preset, Int, Int) = {
            switch resolution {
            case "720p": return (.hd1280x720, 1280, 720)
            case "4K":   return (.hd4K3840x2160, 3840, 2160)
            default:     return (.hd1920x1080, 1920, 1080)
            }
        }()
        return portrait ? (preset, h, w) : (preset, w, h)
    }

    /// Rebuild capture + encode for the current resolution/fps/
    /// orientation. Safe to call while streaming; the Mac re-reads
    /// dimensions from the metadata frame we re-send (and from SPS).
    private func reconfigureVideo() async {
        // Encoder is rebuilt below — the next frame takes a moment, so
        // give the watchdog a warm-up window instead of the tight stall
        // threshold.
        lastVideoFrameAt = Date()
        hasProducedVideoFrame = false
        var config = videoDims(resolution: currentResolution, portrait: encoderIsPortrait)
        // Setting an unsupported preset raises an *Objective-C* exception
        // (uncatchable in Swift → crash), so fall back to 1080p if the
        // device can't do what was asked (e.g. 4K on some hardware).
        if !captureSession.canSetSessionPreset(config.preset) {
            Self.log.error("camera preset \(config.preset.rawValue, privacy: .public) unsupported; falling back to 1080p")
            config = videoDims(resolution: "1080p", portrait: encoderIsPortrait)
        }
        captureSession.beginConfiguration()
        if captureSession.canSetSessionPreset(config.preset) {
            captureSession.sessionPreset = config.preset
        }
        captureSession.commitConfiguration()

        let newEncoder = H264Encoder(width: Int32(config.width), height: Int32(config.height),
                                     fps: currentFps,
                                     bitrate: VideoEncodingPolicy.bitrate(width: config.width, height: config.height, fps: currentFps))
        do {
            try await newEncoder.start { [weak self] frame in
                Task { @MainActor in self?.handleEncodedFrame(frame) }
            }
            encoder = newEncoder
            // Re-point the video output's delegate at the new encoder.
            captureSession.beginConfiguration()
            for output in captureSession.outputs {
                if let video = output as? AVCaptureVideoDataOutput {
                    video.setSampleBufferDelegate(newEncoder, queue: queue)
                    videoOutput = video
                }
            }
            captureSession.commitConfiguration()

            metadata = IBStreamMetadata(deviceName: UIDevice.current.name,
                                        width: config.width, height: config.height,
                                        fps: currentFps,
                                        bitrateBps: VideoEncodingPolicy.bitrate(width: config.width, height: config.height, fps: currentFps))
            if let connection, connection.state == .ready {
                sendMetadata(on: connection)
            }
        } catch {
            Self.log.error("reconfigureVideo failed: \(error, privacy: .public)")
        }
    }

    /// Reconfigure capture + encode for a new resolution / frame rate.
    func applyVideoConfig(resolution: String, fps: Int) async {
        currentResolution = resolution
        currentFps = fps
        await reconfigureVideo()
    }

    // MARK: - Orientation

    /// The wire stream should be upright for however the user holds the
    /// phone: portrait must arrive as portrait (1080×1920), not squashed
    /// into the sensor-native landscape raster. We set the capture
    /// connection's `videoRotationAngle` (hardware rotation) and, when
    /// the aspect class flips, rebuild the encoder with swapped dims.
    private func observeDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let orientation = UIDevice.current.orientation
            Task { @MainActor in self?.applyDeviceOrientation(orientation) }
        }
        applyDeviceOrientation(UIDevice.current.orientation)
    }

    /// Device orientation → capture rotation angle (back camera).
    /// UIDeviceOrientation is mirrored against interface orientation:
    /// device landscapeLeft = top edge points left = sensor-native (0°).
    /// Returns nil for faceUp / faceDown / unknown — keep the last angle.
    private static func rotationAngle(for orientation: UIDeviceOrientation) -> CGFloat? {
        switch orientation {
        case .portrait:           return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft:      return 0
        case .landscapeRight:     return 180
        default:                  return nil
        }
    }

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        guard let angle = Self.rotationAngle(for: orientation) else { return }
        guard angle != currentRotationAngle else { return }
        currentRotationAngle = angle
        let portrait = angle == 90 || angle == 270

        if let connection = videoOutput?.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                Self.forensic("videoRotationAngle → \(Int(angle)) (portrait=\(portrait))")
            } else {
                Self.forensic("videoRotation \(Int(angle)) NOT supported on this connection/preset")
            }
        }
        if portrait != encoderIsPortrait {
            encoderIsPortrait = portrait
            Task { await reconfigureVideo() }
        }
    }

    // MARK: - Camera position

    /// Flip between the front and back cameras (local UI button).
    func toggleCamera() {
        switchCamera(to: features.cameraPosition.toggled)
    }

    /// Switch the streaming camera. Safe while streaming — the session
    /// swaps its video input in place and keeps the same output/encoder.
    func switchCamera(to position: IBCameraPosition) {
        let target: AVCaptureDevice.Position = position == .front ? .front : .back
        guard target != currentCameraPosition else {
            features.setCameraPosition(position)
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target) else {
            Self.log.error("no camera for position \(position.rawValue, privacy: .public)")
            return
        }
        captureSession.beginConfiguration()
        if let videoInput {
            captureSession.removeInput(videoInput)
        }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(newInput) {
                captureSession.addInput(newInput)
                self.videoInput = newInput
                currentCameraPosition = target
                features.setCameraPosition(position)
                Self.log.info("camera switched to \(position.rawValue, privacy: .public)")
            } else if let old = videoInput {
                captureSession.addInput(old)
                Self.log.error("cannot add \(position.rawValue, privacy: .public) camera input")
            }
        } catch {
            if let old = videoInput { captureSession.addInput(old) }
            Self.log.error("camera switch failed: \(error, privacy: .public)")
        }
        captureSession.commitConfiguration()
        // Swapping the input creates a NEW capture connection, which
        // resets the rotation angle — re-apply it or a camera switch
        // silently returns the stream to landscape.
        if let connection = videoOutput?.connection(with: .video),
           connection.isVideoRotationAngleSupported(currentRotationAngle) {
            connection.videoRotationAngle = currentRotationAngle
        }
    }

    // MARK: - Setup

    private func requestPermissions() async {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        if !camera || !mic {
            Self.log.error("permissions denied — camera=\(camera, privacy: .public) mic=\(mic, privacy: .public)")
        }
    }

    /// Sendable hop for the non-Sendable AV objects produced by
    /// `configureCaptureSession` on the capture queue.
    private struct ConfigureOutcome: @unchecked Sendable {
        let input: AVCaptureDeviceInput?
        let output: AVCaptureVideoDataOutput?
        let error: Error?
    }

    /// Runs on the capture queue (never the main thread — the commit
    /// blocks for several hundred ms). Returns the created input/output
    /// so the caller can assign them on the main actor.
    private nonisolated static func configureCaptureSession(
        _ captureSession: AVCaptureSession,
        preset: AVCaptureSession.Preset,
        rotationAngle: CGFloat,
        position: AVCaptureDevice.Position,
        delegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?,
        delegateQueue: DispatchQueue
    ) throws -> (AVCaptureDeviceInput, AVCaptureVideoDataOutput) {
        captureSession.beginConfiguration()
        // Never set a preset the session can't take — that raises an
        // uncatchable NSException. Anything the device lacks stays at the
        // session default.
        if captureSession.canSetSessionPreset(preset) {
            captureSession.sessionPreset = preset
        } else {
            Logger(subsystem: "com.remotecrab", category: "capture")
                .error("initial camera preset \(preset.rawValue, privacy: .public) unsupported; using \(captureSession.sessionPreset.rawValue, privacy: .public)")
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "RemoteCrab", code: -1, userInfo: [NSLocalizedDescriptionKey: "No camera"])
        }

        let videoInput = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(delegate, queue: delegateQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Deliberately NO audio input on the capture session. The mic is
        // captured separately by `MicrophoneEncoder` (AVAudioEngine); an
        // AVCaptureDeviceInput(audio) here makes AVCaptureSession manage
        // the app's AVAudioSession (its default automatic config), which
        // competes with the encoder and — once `UIBackgroundModes: [audio]`
        // is declared — makes the mic's `.playAndRecord` activation fail
        // with "Session activation failed" (561017449). Nothing consumes a
        // capture-session audio output anyway.
        captureSession.automaticallyConfiguresApplicationAudioSession = false

        captureSession.commitConfiguration()

        // Apply the hold orientation now so the very first frames come
        // out upright (connection exists once the output is committed).
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                Self.forensic("initial videoRotationAngle → \(Int(rotationAngle))")
            } else {
                Self.forensic("initial videoRotation \(Int(rotationAngle)) NOT supported")
            }
        }
        // NOTE: startRunning is intentionally NOT called here — it blocks
        // ~1 s. The caller starts the session on the capture queue.
        return (videoInput, videoOutput)
    }

    // MARK: - Bonjour listener

    /// Preferred fixed port so the Mac can reach us without Bonjour.
    static let preferredPort: UInt16 = 8765

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true   // AWDL: accept direct Wi-Fi when no LAN exists

        // Try the fixed port first (manual-IP fallback); fall back to a
        // dynamic port if it's taken.
        let listener: NWListener
        if let fixed = NWEndpoint.Port(rawValue: Self.preferredPort),
           let fixedListener = try? NWListener(using: parameters, on: fixed) {
            listener = fixedListener
        } else {
            listener = try NWListener(using: parameters)
        }
        listener.service = NWListener.Service(
            name: defaultServiceName(),
            type: IBServiceType.tcp,
            domain: IBServiceType.domain
        )
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                Forensic.log("[hs] new connection accepted")
                self?.accept(connection: connection)
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        Self.log.info("Bonjour publishing: \(IBServiceType.tcp, privacy: .public) / \(self.defaultServiceName(), privacy: .public)")
    }

    private func refreshNetworkInfo() {
        listeningPort = listener?.port?.rawValue
        localAddress = Self.wifiAddress()
    }

    private func defaultServiceName() -> String {
        "RemoteCrab — \(UIDevice.current.name)"
    }

    /// The iPhone's WiFi (en0) IPv4 address, for the manual-connect hint.
    private static func wifiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }

    private func handleListenerState(_ state: NWListener.State) {
        Forensic.log("[e2e] listener state: \(state)")
        switch state {
        case .ready:
            Self.log.info("listener ready")
            refreshNetworkInfo()
            Forensic.log("[e2e] listener port: \(String(describing: self.listener?.port))")
        case .failed(let error):
            Self.log.error("listener failed: \(error, privacy: .public)")
            connectionState = .failed
            failureReason = .network
        case .cancelled:
            connectionState = connection == nil ? .idle : .connected
        default:
            break
        }
    }

    /// A Mac just opened a TCP connection. We do NOT stream yet: the
    /// Mac must first identify itself with a `clientHello`, then the
    /// pairing policy decides whether it becomes the owner.
    ///
    /// If another Mac already owns the session we answer `busy` and
    /// close the newcomer without disturbing the owner — that is the
    /// fix for multiple Macs fighting over one iPhone.
    private func accept(connection newConnection: NWConnection) {
        Forensic.log("[hs] accept ownerSet=\(connection != nil) pendingSet=\(pendingConnection != nil)")
        // Deliberately does **not** cancel a handshake that is already in
        // progress. It used to, unconditionally, which made the single pending
        // slot "last caller wins": two computers both retrying every few
        // seconds kicked each other off the phone forever, and the one holding
        // a valid token always won — so a Windows PC could be starved
        // indefinitely by a Mac on the same network.
        //
        // `handleHello` now decides, and it has the hello (this function does
        // not): the newcomer is told to wait, unless it is already paired, in
        // which case it would be accepted immediately and it is what the user
        // is trying to switch to.
        if pendingConnection != nil {
            Forensic.log("[hs] a handshake is already in progress — the newcomer will be told to wait")
        }
        beginHandshake(with: newConnection)
    }

    private func beginHandshake(with conn: NWConnection) {
        let parser = IBWire.Parser()
        candidate = conn
        candidateParser = parser
        let token = UUID()
        handshakeToken = token

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleCandidateState(state, token: token) }
        }
        conn.start(queue: queue)
        readHello(on: conn, parser: parser, token: token)

        // Legacy fallback: an old Mac never sends a hello. After 3 s,
        // admit it first-come so an upgrade doesn't brick the pairing.
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            // `try?` swallows the CancellationError, and a cancelled sleep
            // returns IMMEDIATELY — so without this guard, cancelling the task
            // (which `handleHello` now does the moment a hello arrives) made the
            // fallback run at once instead of not at all: the same connection
            // got `off` and then `accepted` ~10 ms apart, and the computer was
            // admitted as "Computer (legacy)". A cancelled task must stop here.
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, self.handshakeToken == token,
                  self.connection == nil, self.pendingConnection == nil,
                  self.pendingChallenge == nil else { return }
            // A connection that never identifies itself is not a RemoteCrab
            // receiver — every build since the multi-computer handshake sends a
            // `clientHello`. The old "admit first-come" fallback here was a
            // bigger hole than the presented token: it needed no credential at
            // all, just a TCP connect to this port. Deny and close.
            Self.log.info("clientHello timeout — refusing an unidentified connection")
            Forensic.log("[hs] clientHello timeout — denied (no identity)")
            self.sendSessionReply(IBSessionReply(result: .denied), on: conn)
            self.queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
        }
    }

    private func readHello(on conn: NWConnection, parser: IBWire.Parser, token: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.handshakeToken == token else { return }
                if let data, !data.isEmpty {
                    for frame in parser.append(data) where frame.kind == .clientHello {
                        if let hello = try? IBWire.decodeClientHello(frame) {
                            self.handleHello(hello, on: conn, token: token)
                            return
                        }
                    }
                }
                if error != nil { conn.cancel(); return }
                if isComplete { return }
                self.readHello(on: conn, parser: parser, token: token)
            }
        }
    }

    private func handleHello(_ hello: IBClientHello, on conn: NWConnection, token: UUID) {
        Forensic.log("[hs] hello id=\(hello.id) ownerSet=\(connection != nil) sameToken=\(handshakeToken == token)")
        guard handshakeToken == token else { return }

        // A hello arrived, so this is not a legacy Mac — disarm the 3 s
        // first-come fallback for this connection. Without this, the `off` /
        // `busy` replies above did not cancel it, and 3 s later it admitted the
        // very computer we had just refused as "Computer (legacy)" — which is
        // why Disconnect appeared to reconnect under a new name.
        handshakeTask?.cancel()
        handshakeTask = nil

        // Remember every computer that reaches us — before any approval —
        // so "Choose a Computer" can list a machine that has never paired
        // (e.g. this Windows PC on its first connect).
        pairingStore.noteSeen(hello, alsoKnown: Set(onlineComputers.map(\.id)))
        refreshPairedMacs()
        if let existing = connection, existing !== conn {
            // A different Mac while someone owns the session keeps the
            // owner. But the SAME Mac reconnecting (its old socket died,
            // possibly without us noticing) takes its session back — and
            // a dead-but-still-"ready" owner never blocks anyone.
            let sameMac = (connectedMacId != nil && connectedMacId == hello.id)
            if existing.state == .ready && !sameMac {
                replyBusy(on: conn, ownerName: connectedMacName ?? "another computer")
                return
            }
            existing.cancel()
            clearOwner(reason: .replaced)
        }
        // A second computer showed up while the first was mid-handshake.
        if let pending = pendingConnection, pending !== conn {
            let newcomerIsPaired = pairingStore.paired.contains { $0.id == hello.id }
            let incumbentIsPaired = pendingHello.map { incumbent in
                pairingStore.paired.contains { $0.id == incumbent.id }
            } ?? false
            if newcomerIsPaired && !incumbentIsPaired {
                // The newcomer would be accepted immediately and it is the one
                // the user just picked on this phone, so it takes the slot.
                // Clearing all three here matters: leaving `pendingMacName`
                // set would keep an approval card on screen for a connection
                // that no longer exists, and the user would tap Allow on a
                // dead card.
                let incumbent = pendingMacName ?? "another computer"
                Forensic.log("[hs] paired newcomer takes the pending slot from \(incumbent)")
                pending.cancel()
                clearPending()
            } else {
                replyBusy(on: conn, ownerName: pendingMacName ?? "another computer")
                return
            }
        }
        // `effectivePreferred`, not `preferred`: once the 30 s grace is spent
        // this is nil, so the policy sees "no preference" and the door is open
        // to every computer again. Aiming it at `preferred` here is what made
        // one failed switch lock the phone out for ten minutes — the chosen
        // computer was asleep or had been denied, and it still refused
        // everyone else until the TTL ran out.
        let decision = PairingPolicy.decide(hello: hello, paired: pairingStore.paired, owner: nil,
                                            preferred: pairingStore.effectivePreferred(),
                                            disconnected: pairingStore.disconnected,
                                            current: pairingStore.current)
        Self.log.info("clientHello \(hello.name, privacy: .public) -> \(String(describing: decision), privacy: .public)")

        noteOutcome(decision, for: hello)
        switch decision {
        case .busy(let ownerName):
            replyBusy(on: conn, ownerName: ownerName)
        case .off(let name):
            // The user disconnected this computer; tell it to stand down, then
            // close so it does not sit on an open socket.
            sendSessionReply(IBSessionReply(result: .off, ownerName: name), on: conn)
            queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
        case .accept, .pending:
            // A computer the phone already paired with must *prove* it holds the
            // token, not merely present it — presenting a secret is not proof,
            // and the token crosses the wire in the clear. This covers both a
            // valid presented token (`.accept`) and a wrong/absent one for a
            // paired id (`.pending`): the MAC decides, not the badge.
            let paired = pairingStore.paired.first { $0.id == hello.id }
            if let paired, let nonce = hello.nonce, !nonce.isEmpty {
                beginChallenge(hello: hello, mac: paired, clientNonce: nonce, on: conn, token: token)
            } else if case .accept = decision, let paired {
                // Legacy receiver: it presented a valid token but cannot do the
                // exchange. Accept it, but say plainly the session is not
                // authenticated — refusing would brick every computer on the day
                // this shipped, and the phone cannot update the receiver.
                Self.log.info("clientHello accepted by token only — no peerAuth, session unauthenticated")
                Forensic.log("[auth] legacy receiver (no nonce) — session unverified")
                sendSessionReply(IBSessionReply(result: .accepted, token: paired.token), on: conn)
                grant(connection: conn, mac: paired, platform: hello.platform,
                      capabilities: hello.capabilities ?? [])
            } else if case .accept = decision {
                // Shouldn't happen, but never strand the Mac.
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                setPending(connection: conn, hello: hello, name: hello.name)
            } else {
                // First pairing (unknown computer), or a paired id whose legacy
                // token did not match — ask the human (the TOFU window).
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                setPending(connection: conn, hello: hello, name: hello.name)
                // Headless e2e: auto-approve so a run needs no phone tap.
                if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_AUTOPAIR"] == "1" {
                    approvePendingMac()
                }
            }
        }
    }

    // MARK: - Identity challenge (`PeerAuth`)

    /// Ask a paired computer to prove it holds the token.
    ///
    /// Sends `pending` carrying the phone's nonce and its own MAC (no approval
    /// card — `pendingConnection` is deliberately untouched), then waits on the
    /// same socket for a `clientProof`.
    private func beginChallenge(hello: IBClientHello, mac: PairedMac, clientNonce: String,
                                on conn: NWConnection, token: UUID) {
        let serverNonce = PeerAuth.newNonce()
        let serverMac = PeerAuth.serverMac(token: mac.token, pcID: hello.id,
                                           clientNonce: clientNonce, serverNonce: serverNonce)
        let expectedClientMac = PeerAuth.clientMac(token: mac.token, pcID: hello.id,
                                                   clientNonce: clientNonce, serverNonce: serverNonce)
        Forensic.log("[auth] challenge sent for \(hello.id.prefix(8))")
        sendSessionReply(IBSessionReply(result: .pending, nonce: serverNonce, mac: serverMac,
                                        capabilities: [PeerAuth.capability]), on: conn)

        let parser = candidateParser ?? IBWire.Parser()
        var challenge = PendingChallenge(connection: conn, hello: hello, mac: mac,
                                         expectedClientMac: expectedClientMac,
                                         handshakeToken: token, timeout: nil)
        challenge.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.pendingChallenge?.handshakeToken == token else { return }
            self.failChallenge(reason: "no clientProof", on: conn)
        }
        pendingChallenge = challenge

        readProof(on: conn, parser: parser, token: token)
    }

    private func readProof(on conn: NWConnection, parser: IBWire.Parser, token: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let challenge = self.pendingChallenge,
                      challenge.handshakeToken == token, challenge.connection === conn else { return }
                if let data, !data.isEmpty {
                    for frame in parser.append(data) where frame.kind == .clientProof {
                        if let proof = try? IBWire.decodeClientProof(frame) {
                            self.completeChallenge(proof: proof, token: token)
                            return
                        }
                    }
                }
                if error != nil {
                    self.failChallenge(reason: "link lost", on: conn)
                    return
                }
                if isComplete {
                    self.failChallenge(reason: "connection closed", on: conn)
                    return
                }
                self.readProof(on: conn, parser: parser, token: token)
            }
        }
    }

    private func completeChallenge(proof: IBClientProof, token: UUID) {
        guard let challenge = pendingChallenge, challenge.handshakeToken == token else { return }
        challenge.timeout?.cancel()
        pendingChallenge = nil

        if PeerAuth.matches(expected: challenge.expectedClientMac, presented: proof.mac) {
            Forensic.log("[auth] receiver proved the token for \(challenge.hello.id.prefix(8))")
            pairingStore.noteOutcome(.streaming, for: challenge.hello.id)
            refreshPairedMacs()
            sendSessionReply(IBSessionReply(result: .accepted), on: challenge.connection)
            grant(connection: challenge.connection, mac: challenge.mac,
                  platform: challenge.hello.platform,
                  capabilities: challenge.hello.capabilities ?? [])
        } else {
            refuseChallenge(challenge, reason: "wrong MAC")
        }
    }

    /// Drop an unproven challenge and tell the computer why.
    ///
    /// `denied`, not `busy`, and no retry: this is not a network fault and not a
    /// human refusal, it is a machine that could not prove it is the paired
    /// computer. Saying "denied" keeps the receiver's own reconnect loop honest.
    private func failChallenge(reason: String, on conn: NWConnection) {
        guard let challenge = pendingChallenge, challenge.connection === conn else { return }
        refuseChallenge(challenge, reason: reason)
    }

    private func refuseChallenge(_ challenge: PendingChallenge, reason: String) {
        challenge.timeout?.cancel()
        pendingChallenge = nil
        Self.log.error("REFUSED a computer that failed the identity challenge (\(reason, privacy: .public))")
        Forensic.log("[auth] REFUSED \(challenge.hello.id.prefix(8)): \(reason)")
        pairingStore.noteOutcome(.denied, for: challenge.hello.id)
        refreshPairedMacs()
        sendSessionReply(IBSessionReply(result: .denied), on: challenge.connection)
        queue.asyncAfter(deadline: .now() + 0.4) { challenge.connection.cancel() }
    }

    /// Turn a pairing decision into something the computer list can show.
    ///
    /// This is the only way a user can tell "my PC cannot see the iPhone"
    /// (a network problem) from "my PC found it and another computer is using
    /// it" (a switching problem) — from the outside the two are identical, and
    /// that ambiguity is what made this undiagnosable.
    private func noteOutcome(_ decision: PairingDecision, for hello: IBClientHello) {
        let outcome: AttemptOutcome
        switch decision {
        case .accept: outcome = .streaming
        case .pending: outcome = .waitingApproval
        case .busy(let ownerName): outcome = .refusedBusy(owner: ownerName)
        // The user asked for it to stay off, so "not streaming" is the honest
        // persisted outcome; the picker's own state carries the nuance.
        case .off: outcome = .denied
        }
        pairingStore.noteOutcome(outcome, for: hello.id)
        refreshPairedMacs()
    }

    /// Promote a connection to the session owner and start streaming.
    /// `platform` is the value from THIS connection's `clientHello`
    /// (nil for a legacy Mac or the timeout fallback) — the live handshake
    /// is the source of truth for ⌘ vs Ctrl, not a remembered lookup.
    /// `capabilities` is that same hello's declared abilities, so the UI can
    /// hide a control the receiver cannot back.
    private func grant(connection conn: NWConnection, mac: PairedMac?, platform: String? = nil,
                       capabilities: [IBClientHello.Capability] = []) {
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate = nil
        candidateParser = nil
        pendingChallenge?.timeout?.cancel()
        pendingChallenge = nil
        clearPending()

        // The preferred Mac arrived — the switch is done, open the door, and
        // remember it: the phone now serves this computer until the user says
        // otherwise.
        if let mac, mac.id == pairingStore.preferredId {
            Forensic.log("[gv] granted: clearing preferred for \(mac.id.prefix(8))")
            pairingStore.clearPreferred()
            // The switch SUCCEEDED, so the "gave up waiting" note must not be
            // raised by the refresh below: `preferredMac` is still the armed
            // record while `effectivePreferred()` is now nil (we just cleared
            // it), which is exactly the condition that raises it. Clear both
            // first so a successful switch never flashes "gave up".
            preferredMac = nil
            preferredGaveUp = nil
        }
        if let mac {
            pairingStore.setCurrent(id: mac.id, name: mac.name)
        }
        refreshPairedMacs()

        ownerMac = mac
        connection = conn
        // Belt and braces: `clearOwner` already wiped the previous
        // computer on every path that leads here, but this is the ONE place
        // a computer becomes the owner, so it is the one place that must not
        // inherit anybody's identity. The old code cleared nineteen fields
        // on the way out and none of the four that named the peer, which is
        // why "访达" survived the switch to Windows.
        clearPeerIdentity()
        connectedMacName = mac?.name ?? "Computer (legacy)"
        connectedMacId = mac?.id
        // Platform drives the keyboard UI (⌘ vs Ctrl). The live handshake
        // is authoritative; fall back to the seen list, then to macOS.
        connectedPlatform = platform
            ?? mac.flatMap { pairingStore.platform(for: $0.id) }
            ?? "macos"
        // From this connection's hello only, never a remembered lookup: a
        // receiver that stopped advertising a capability must lose it, the same
        // way the live handshake is the authority for platform.
        peerCapabilities = capabilities
        connectionState = .connected
        failureReason = nil
        startOwnerWatchdog()
        Self.log.info("session granted to \(self.connectedMacName ?? "?", privacy: .public)")

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleOwnerState(state, on: conn) }
        }

        let broadcaster = IBEventBroadcaster(connection: conn, queue: queue)
        self.broadcaster = broadcaster
        broadcaster.send(features.snapshot())

        // Metadata + cached parameter sets so the decoder can start.
        sendMetadata(on: conn)
        for param in [lastSPSFrame, lastPPSFrame] {
            guard let param else { continue }
            conn.send(content: IBWire.encode(frame: param),
                      completion: .contentProcessed { _ in })
        }

        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_MIC"] == "1", !features.micOn {
            features.set(feature: .microphone, enabled: true)
        }
        // E2E asserts on live video; the product default is camera-off,
        // so headless runs opt back in explicitly.
        if ProcessInfo.processInfo.environment["REMOTECRAB_AUTOSTREAM"] == "1", !features.cameraOn {
            features.set(feature: .camera, enabled: true)
        }
        // The speaker is resumed the way the camera is: it only takes effect
        // once a session exists, so restoring it here cannot capture anything
        // on a computer we are not connected to.
        //
        // NOT on Windows, and that is the whole point of the policy: there the
        // speaker entry was hidden, so resuming the habit switched the
        // microphone off with no control anywhere to switch it back on
        // (`AudioModeArbiter` ranks the speaker above the mic).
        if SpeakerRestorePolicy.shouldResume(
            habit: UserDefaults.standard.bool(forKey: Self.speakerHabitKey),
            alreadyOn: features.speakerOn,
            connectedIsWindows: connectedIsWindows,
            e2eForcedMicrophone: ProcessInfo.processInfo.environment["REMOTECRAB_E2E_MIC"] == "1"
        ) {
            features.set(feature: .microphone, enabled: false)
            features.set(feature: .speaker, enabled: true)
        }
        syncAudioMode(features)
        // Resume the mirror if it was on when the link dropped. No-op when
        // the feature is off or `start` was already sent.
        syncScreen()
        // E2E: auto-start the mirror ~3 s after the session is accepted so
        // the Mac's capture path is verifiable from the receiver log.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SCREEN"] == "1", !features.screenOn {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.startScreenMirror()
                Forensic.log("[e2e] screen mirror start requested")
                // Exercise the absolute-input path without a human finger:
                // a click at the window centre plus a scroll. The Mac logs
                // each injected input, so the receiver-log assertion proves
                // the full wire → CGEventPost chain.
                if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SCREEN_INPUT"] == "1" {
                    // Wait until the Mac has published a usable target
                    // (`screenInfo.status == .ok`); input sent before that is
                    // silently dropped and makes the e2e flaky.
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if self?.screenInfo?.status == .ok { break }
                    }
                    // Scroll FIRST, before any click. Nothing has put the cursor in the
                    // mirrored window yet, so the Mac must place it once or
                    // the scroll event has no window to land in. Then click,
                    // then two more scrolls that must leave the cursor
                    // exactly where the click put it.
                    //
                    // "Placed once, then left alone" vs "moved every time" IS
                    // the regression: a two-finger swipe used to teleport the
                    // cursor to the finger, which is most of why the pointer
                    // never landed where the user tapped.
                    //
                    // The settle delay matters: the PHONE can see
                    // `screenInfo.status == .ok` before the Mac's own
                    // `lastScreenInfo` is populated (that assignment hops
                    // through the main actor), and `handleScreenInput` drops
                    // input until it lands. Sending on the phone's signal
                    // alone lost the first frame and left the "place once"
                    // branch unexercised.
                    try? await Task.sleep(for: .seconds(2))
                    self?.sendScreenInput(IBScreenInput(action: .scroll, u: 0.5, v: 0.5, dx: 0, dy: 0.05))
                    Forensic.log("[e2e] screen input scroll 1/3 sent (pre-click)")
                    try? await Task.sleep(for: .milliseconds(700))
                    self?.sendScreenInput(IBScreenInput(action: .click, u: 0.5, v: 0.5))
                    Forensic.log("[e2e] screen input click sent")
                    try? await Task.sleep(for: .milliseconds(700))
                    for i in 2...3 {
                        self?.sendScreenInput(IBScreenInput(action: .scroll, u: 0.5, v: 0.5, dx: 0, dy: 0.05))
                        Forensic.log("[e2e] screen input scroll \(i)/3 sent (post-click)")
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_INPUT"] == "1" {
            runE2EInputSequence()
        }
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_DRAG"] == "1" {
            runE2EDragSequence()
        }
        // E2E: send generated file(s) so the receive + Finder-reveal
        // path is verifiable from the receiver log. A value >1 also
        // exercises the serial multi-file queue.
        if let raw = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SEND_FILE"],
           let count = Int(raw), count > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                var urls: [URL] = []
                for i in 1...count {
                    let data = Data(repeating: UInt8(0xAB &+ i), count: 1_500_000)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("remotecrab-e2e-file-\(i).bin")
                    try? data.write(to: url)
                    urls.append(url)
                }
                self?.sendFiles(at: urls)
            }
        }
        // E2E: push a known clipboard string so the Mac receive path is
        // verifiable from the receiver log.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_CLIPBOARD"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                UIPasteboard.general.string = "RemoteCrab-clipboard-e2e"
                self?.sendClipboard()
            }
        }
        // E2E: exercise the app switcher headlessly — request the Mac's
        // app list, then activate the app named in REMOTECRAB_E2E_SWITCH
        // (a bundle id). The Mac log confirms "activated app …".
        if let target = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_SWITCH"], !target.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.requestMacApps()
                try? await Task.sleep(for: .seconds(2))
                self?.activateMacApp(id: target)
                Forensic.log("[e2e] switch requested: \(target)")
            }
        }
        // E2E: exercise the quit path headlessly — REMOTECRAB_E2E_QUIT is a
        // bundle id; the Mac log confirms "quitApp … accepted=…".
        if let target = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_QUIT"], !target.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.quitMacApp(id: target, force: true)
                Forensic.log("[e2e] quit requested: \(target)")
            }
        }
        // E2E: "Extended Display" — create the Mac's virtual display and
        // stream it (Mac log: "virtual display created" +
        // "streaming extended display").
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_EXTEND"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                // Exercise the real user path (the top-bar toggle), which
                // also covers "extend without a preceding start".
                self?.toggleExtendedDisplay()
                // …then switch back to window mirroring (the mutual switch):
                // the Mac must resume following the frontmost window.
                //
                // Wait for the extended display to actually be established
                // (screenInfo reports appId "extended") rather than sleeping a
                // fixed interval: the virtual display takes ~3 s to appear, and
                // switching before that took the "stop the viewer" branch
                // instead of "switch sources", so this assertion could never
                // pass — the hook was testing the wrong branch.
                for _ in 0..<40 {                       // ≤10 s
                    try? await Task.sleep(for: .milliseconds(250))
                    if self?.isExtendedDisplayOn == true { break }
                }
                self?.toggleScreenMirror()
            }
        }
        // E2E: the switcher's "Open App…" list — REMOTECRAB_E2E_INSTALLED_APPS=1
        // requests it; the Mac log confirms "published N installed apps".
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_INSTALLED_APPS"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.requestInstalledApps()
                Forensic.log("[e2e] installed apps requested")
            }
        }
        // E2E: REMOTECRAB_E2E_LINK_LOSS=1 drops the owner link the way a
        // network stall does — the owner watchdog's decision, without
        // needing the Mac to be `kill -STOP`ed. Stands in for the bug where
        // the watchdog cleared the owner but left `connectionState` at
        // `.connected`, so the UI claimed a live link while every switch
        // tap was dropped (lesson 87). The suite asserts the state really
        // becomes `.failed` and that a command issued afterwards is
        // *refused visibly* rather than silently.
        //
        // The `fired` flag is load-bearing and is NOT the other hooks' pattern:
        // this one *causes* a reconnect, and every reconnect runs `grant()`,
        // so an unguarded hook re-arms itself and the phone loops
        // offline → reconnect → offline forever (a 6 s + 3 s cycle, measured).
        // The other hooks only replay a frame, so re-arming them is harmless.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_LINK_LOSS"] == "1",
           !e2eLinkLossFired {
            e2eLinkLossFired = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self else { return }
                Forensic.log("[e2e] simulating owner silence")
                self.lastInboundAt = Date(timeIntervalSinceNow: -30)
                self.checkOwnerLiveness()
                Forensic.log("[e2e] after link loss state=\(self.connectionState.debugName) hint=\(self.transientHint ?? "none")")
                // The command that used to vanish without a trace.
                self.activateMacApp(id: "com.apple.Safari", windowTitle: nil)
                try? await Task.sleep(for: .milliseconds(300))
                Forensic.log("[e2e] after refused switch state=\(self.connectionState.debugName) hint=\(self.transientHint ?? "none")")
            }
        }
        // E2E: the switcher's Desktop quick action — REMOTECRAB_E2E_DESKTOP=1
        // sends showDesktop; the Mac log confirms "showDesktop requested".
        //
        // 20 s, i.e. AFTER the extend/mutual-switch hook (5 s + up to 10 s of
        // polling). showDesktop hides every app, so if it lands while the
        // switch back to window mirroring is in flight the frontmost app has
        // no eligible window and the Mac correctly falls back to capturing the
        // whole display (lesson 73) — no "follow" at all, for a reason that
        // has nothing to do with the mutual toggle.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_DESKTOP"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.sendSystemCommand(IBSystemCommand(command: .showDesktop))
                Forensic.log("[e2e] showDesktop sent")
            }
        }
        // E2E: exercise the voice pipeline without real speech —
        // REMOTECRAB_E2E_VOICE=1 simulates "say → pause (recognizer closes
        // the segment and starts a fresh one) → keep talking". The Mac log
        // must show the full text and NO backspace from the pause.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_VOICE"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.beginVoiceSession()
                self?.updateVoiceText("前面输入的内容", committed: 7)   // utterance finalized → typed
                try? await Task.sleep(for: .milliseconds(400))
                self?.updateVoiceText("前面输入的内容新词", committed: 7) // pause: live tail, not typed yet
                try? await Task.sleep(for: .milliseconds(400))
                self?.finishVoiceText("前面输入的内容新词")              // final flushes the tail
                try? await Task.sleep(for: .milliseconds(300))
                // A final that LOOKS like a command — must not erase.
                self?.updateVoiceText("变成大写", committed: 4)
                try? await Task.sleep(for: .milliseconds(300))
                self?.finishVoiceText("变成大写")
                Forensic.log("[e2e] voice sequence sent")
            }
        }
        // holds it, types "a" with it, then releases. The Mac log confirms
        // "modifier key event: keycode=…" and the key events.
        if let raw = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_MODIFIER"],
           let code = UInt16(raw) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                let mask: UInt8 = code == 58 ? 4 : (code == 55 ? 8 : (code == 59 ? 2 : 1))
                self?.sendKey(KeyEvent(action: .down, keycode: code))
                try? await Task.sleep(for: .milliseconds(200))
                self?.sendKey(KeyEvent(action: .down, keycode: 0, modifiers: mask))
                self?.sendKey(KeyEvent(action: .up, keycode: 0, modifiers: mask))
                self?.sendKey(KeyEvent(action: .up, keycode: code))
                // Also exercise the IME text path (locked modifier + typed
                // character), which is what real typing uses.
                self?.sendKey(KeyEvent(action: .text, text: "a", modifiers: mask))
                Forensic.log("[e2e] modifier sequence sent: \(code) mask=\(mask)")
            }
        }
        // E2E: request the window list so the Mac's capture path is
        // verifiable from its log ("published N windows (M with previews…)").
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_WINDOWS"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.requestMacApps()
                self?.requestMacWindows()
                Forensic.log("[e2e] window list requested")
            }
        }

        parser.reset()
        startReceiving(from: conn)
    }

    private func handleCandidateState(_ state: NWConnection.State, token: UUID) {
        guard handshakeToken == token else { return }
        switch state {
        case .failed, .cancelled:
            handshakeTask?.cancel()
            // Read the dying connection's identity BEFORE clearing anything.
            //
            // This compared `pendingConnection === candidate` *after* setting
            // `candidate = nil`, so the question was always "is nil the slot
            // holder?" — never true, and the three cleanup lines below were
            // dead code. A computer that died mid-approval therefore kept
            // answering `busy` to every other computer, naming itself, until
            // the app was restarted.
            let dying = candidate.map(ObjectIdentifier.init)
            let holder = pendingConnection.map(ObjectIdentifier.init)
            let wasHoldingTheSlot = PendingSlotPolicy.isHeld(byDying: dying, pending: holder)
            // A challenge in flight on the dying connection is abandoned; its
            // timeout must not fire against a socket that is already gone.
            if let challenge = pendingChallenge, challenge.connection === candidate {
                challenge.timeout?.cancel()
                pendingChallenge = nil
            }
            candidate = nil
            candidateParser = nil
            if wasHoldingTheSlot {
                let name = pendingMacName ?? "the computer"
                Forensic.log("[hs] \(name) disconnected while awaiting approval — releasing the slot")
                clearPending()
            }
        default:
            break
        }
    }

    private func replyBusy(on conn: NWConnection, ownerName: String) {
        Self.log.info("refusing Mac: \(ownerName, privacy: .public) already owns the session")
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: queue)
        sendSessionReply(IBSessionReply(result: .busy, ownerName: ownerName), on: conn)
        queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
    }

    private func sendSessionReply(_ reply: IBSessionReply, on conn: NWConnection) {
        Forensic.log("[hs] sendSessionReply \(String(describing: reply.result))")
        guard let data = try? IBWire.encode(sessionReply: reply) else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - UI actions (pairing)

    /// Approve the Mac currently waiting on the iPhone prompt.
    func approvePendingMac() {
        guard let conn = pendingConnection, let hello = pendingHello else { return }
        let mac = pairingStore.pair(hello)
        pairingStore.noteOutcome(.streaming, for: hello.id)
        refreshPairedMacs()
        sendSessionReply(IBSessionReply(result: .accepted, token: mac.token), on: conn)
        grant(connection: conn, mac: mac, platform: hello.platform,
              capabilities: hello.capabilities ?? [])
    }

    /// Deny the waiting Mac and close its connection.
    func denyPendingMac() {
        guard let conn = pendingConnection, let hello = pendingHello else { return }
        pairingStore.noteOutcome(.denied, for: hello.id)
        refreshPairedMacs()
        sendSessionReply(IBSessionReply(result: .denied), on: conn)
        clearPending()
        queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
    }

    /// Drop the current owner (settings / connected banner).
    func disconnectCurrentMac() {
        // Remember the intent. Without this the computer is paired, so it is
        // auto-accepted on its very next dial and the disconnect does not
        // stick — the computer is running its own reconnect loop.
        if let mac = ownerMac {
            pairingStore.markDisconnected(id: mac.id, name: mac.name)
        }
        connection?.cancel()
        clearOwner(reason: .disconnected)
        refreshPairedMacs()
    }

    func forgetPairedMac(id: String) {
        pairingStore.forget(id: id)
        refreshPairedMacs()
    }

    /// Mark a paired Mac as the one this iPhone should serve. If a
    /// different Mac currently owns the session it is dropped; until
    /// the chosen Mac reconnects, every other Mac is answered "busy".
    func setPreferredMac(id: String, name: String? = nil) {
        // Already serving this Mac — a preference would just hold the
        // door against everyone else until it expires.
        guard ownerMac?.id != id else { return }
        pairingStore.setPreferred(id: id, name: nameForComputer(id: id))
        refreshPairedMacs()
        if ownerMac != nil {
            disconnectCurrentMac()
        }
    }

    /// Cancel an outstanding preference — the next Mac to ask gets the
    /// normal pairing treatment again.
    func clearPreferredMac() {
        pairingStore.clearPreferred()
        refreshPairedMacs()
    }

    /// Forget which computer this iPhone is set to, so the next computer to
    /// connect becomes current again (the picker's "Release this iPhone").
    func releaseCurrentComputer() {
        pairingStore.clearCurrent()
        refreshPairedMacs()
    }

    // MARK: - App switcher

    /// Ask the Mac for a fresh running-app list.
    func requestMacApps() {
        broadcaster?.send(IBAppListRequest())
    }

    /// Ask the Mac for a fresh window list (window picker).
    func requestMacWindows() {
        broadcaster?.send(IBWindowListRequest())
    }

    // MARK: - Installed-app launcher

    /// Launch-able applications advertised by the connected computer live
    /// in `peer.installedApps` — same `id` the computer expects for
    /// `launchApp` (bundle id on the Mac, `.lnk` path on Windows), and the
    /// same reason for being there: a launcher listing the Mac's bundle ids
    /// while Windows owns the session is that field outliving its owner.

    /// Whether the launcher is still waiting for that list. `awaiting` is the
    /// only phase that may show a spinner; `answered` is the only one that
    /// may show an empty list, and `unanswered` is what the sheet has to say
    /// when no receiver answered at all.
    @Published private(set) var installedAppsPhase: IBListRequestGate.Phase = .idle
    private var installedAppsGate = IBListRequestGate()
    private var installedAppsExpiryTimer: Timer?
    /// When the current request went out, so the reply can report how long
    /// the receiver actually took. A device log that says "asked" without a
    /// matching "answered … after Nms" cannot tell a working fix from a
    /// hopeful one.
    private var installedAppsAskedAt: Date?

    /// Ask the receiver for its installed apps (launcher sheet).
    ///
    /// With no link there is nobody to answer, so the gate is left `idle`
    /// rather than started — the sheet reads the link itself and says
    /// "not connected", instead of waiting out a deadline to arrive at the
    /// same conclusion through the wrong sentence.
    func requestInstalledApps() {
        guard canReachMac else {
            Forensic.log("[launcher] installed apps requested with no link")
            return
        }
        installedAppsGate.begin(now: Date())
        installedAppsPhase = installedAppsGate.current
        installedAppsAskedAt = Date()
        Forensic.log("[launcher] installed apps requested")
        broadcaster?.send(IBInstalledAppsRequest())
        startInstalledAppsExpiry()
    }

    /// The receiver's answer arrived — the only event that may end a wait.
    private func resolveInstalledApps(_ list: [IBInstalledApp],
                                      bytes: Int = 0, askedAt: Date? = nil) {
        peer.install(installedApps: list)
        installedAppsGate.answer()
        installedAppsPhase = installedAppsGate.current
        stopInstalledAppsExpiry()
        let took = askedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let kb = bytes / 1024
        Forensic.log("[launcher] answered: \(list.count) apps, \(kb)KB, after \(took)ms")
    }

    private func startInstalledAppsExpiry() {
        guard installedAppsExpiryTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireInstalledApps() }
        }
        RunLoop.main.add(timer, forMode: .common)
        installedAppsExpiryTimer = timer
    }

    private func expireInstalledApps() {
        if installedAppsGate.expire(now: Date()) {
            Forensic.log("[launcher] no installed-app reply within \(Int(installedAppsGate.timeout))s")
        }
        installedAppsPhase = installedAppsGate.current
        if installedAppsGate.isSettled { stopInstalledAppsExpiry() }
    }

    private func stopInstalledAppsExpiry() {
        installedAppsExpiryTimer?.invalidate()
        installedAppsExpiryTimer = nil
    }

    /// Launch an installed app on the receiver via `systemCommand(.launchApp)`.
    func launchInstalledApp(_ app: IBInstalledApp) {
        guard canReachMac else {
            reportNoLink()
            return
        }
        let requestId = openCommand(appName: app.name)
        sendSystemCommand(IBSystemCommand(command: .launchApp, argument: app.id,
                                         requestId: requestId))
    }

    /// Bring a Mac app to the front, and optionally raise one specific
    /// window of it (matches the picked window card).
    func activateMacApp(id: String, windowTitle: String? = nil, appName: String? = nil) {
        guard canReachMac else {
            reportNoLink()
            return
        }
        let requestId = openCommand(appName: appName ?? id)
        broadcaster?.send(IBActivateApp(id: id, windowTitle: windowTitle,
                                        requestId: requestId))
    }

    /// Register a command and return the id the receiver will echo back.
    private func openCommand(appName: String) -> String {
        let requestId = UUID().uuidString
        commandLedger.open(requestId, now: Date())
        commandAppNames[requestId] = appName
        startCommandExpiry()
        return requestId
    }

    private func startCommandExpiry() {
        guard commandExpiryTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireCommands() }
        }
        RunLoop.main.add(timer, forMode: .common)
        commandExpiryTimer = timer
    }

    private func expireCommands() {
        for outcome in commandLedger.expire(Date()) {
            Forensic.log("[cmd] unconfirmed \(outcome.requestId.prefix(8))")
            if let message = outcome.message() { showHint(message) }
        }
        if commandLedger.pendingCount == 0 { stopCommandExpiry() }
    }

    private func stopCommandExpiry() {
        commandExpiryTimer?.invalidate()
        commandExpiryTimer = nil
    }

    /// A receiver says it can no longer decode what it has (wire kind 0x25).
    ///
    /// The answer is an IDR, not an error and not silence: a receiver that has
    /// lost a reference frame will otherwise keep displaying a plausible-looking
    /// wrong picture, which is worse than a visible glitch because the user
    /// cannot tell it is wrong. OpenH264's own guidance for a decoder that has
    /// fallen behind is `ForceIntraFrame` (issues #1998, #1163).
    private func handleKeyframeRequest() {
        guard KeyframeRequestPolicy.shouldForceIntraFrame(
            sessionActive: connection != nil,
            cameraOn: features.cameraOn
        ) else {
            Forensic.log("[video-forensic] keyframe request ignored (session=\(connection != nil) camera=\(features.cameraOn))")
            return
        }
        encoder.requestForceIntraFrame()
        Forensic.log("[video-forensic] keyframe request honoured — asking VideoToolbox for an IDR")
    }

    private func resolveCommand(_ result: IBCommandResult) {
        // `resolve` returns nil for an id we never opened (late or duplicate),
        // which must be dropped silently.
        guard commandLedger.resolve(result.requestId) != nil else { return }
        let appName = commandAppNames.removeValue(forKey: result.requestId) ?? ""
        if commandLedger.pendingCount == 0 { stopCommandExpiry() }
        // Success needs no message: the screen visibly changed, and a toast
        // on top of that is noise.
        guard result.status != .ok else { return }
        Forensic.log("[cmd] \(result.requestId.prefix(8)) → \(result.status.rawValue)")
        let outcome = IBCommandOutcome(requestId: result.requestId,
                                       state: .failed(status: result.status),
                                       appName: appName)
        if let message = outcome.message() { showHint(message) }
    }

    /// The single place a dropped link becomes visible to the user. Every
    /// command below funnels through here instead of failing quietly.
    @discardableResult
    private func reportNoLink() -> Bool {
        Forensic.log("[link] command refused — no live link")
        showHint(IBLocale.Error.notConnectedToMac)
        return false
    }

    /// Quit a Mac app. Graceful by default (the app may show a save sheet
    /// on the Mac); `force` terminates immediately and can lose work.
    func quitMacApp(id: String, force: Bool, appName: String? = nil) {
        guard canReachMac else {
            reportNoLink()
            return
        }
        let requestId = openCommand(appName: appName ?? id)
        broadcaster?.send(IBQuitApp(id: id, force: force, requestId: requestId))
        // Optimistic: drop the app's cards from the open window picker
        // immediately. The Mac republishes the list right after the quit
        // and reconciles — if a graceful quit is blocked by an invisible
        // save prompt, the card simply comes back.
        peer.forgetWindow(appId: id)
    }

    // MARK: - File transfer

    /// Serializes file sends — the wire protocol has no per-file stream
    /// id, so two in-flight transfers would interleave chunk frames.
    private let fileSender = SerialFileSender()

    /// Stream a single file to the Mac (offer → chunks → complete).
    /// Safe to call from any surface; a no-op when no Mac owns the session.
    func sendFile(at url: URL) {
        sendFiles(at: [url])
    }

    /// Stream several files to the Mac, strictly one after another.
    func sendFiles(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            await fileSender.enqueue(urls) { [weak self] url in
                await self?.sendFileNow(at: url)
            }
        }
    }

    private func sendFileNow(at url: URL) async {
        guard broadcaster != nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let offer = IBFileOffer(name: name, size: size)
        Forensic.log("[e2e] sendFile \(name) size=\(size)")
        broadcaster?.send(offer)
        fileTransferProgress = 0
        lastFileAck = nil

        // Detached so the chunk loop stays off the main thread; awaited
        // so the serial queue waits for this file to finish.
        await Task.detached(priority: .userInitiated) { [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            let broadcaster = await self.broadcaster
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                await self.finishFileSend(offer)
                return
            }
            var sent: Int64 = 0
            var lastReported = -1
            while true {
                let chunk = (try? handle.read(upToCount: 128 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                broadcaster?.sendFileChunk(chunk)
                sent += Int64(chunk.count)
                if size > 0 {
                    let pct = Int(sent * 100 / size)
                    if pct / 5 != lastReported / 5 {
                        lastReported = pct
                        await self.setFileProgress(Double(sent) / Double(size))
                    }
                }
            }
            try? handle.close()
            await self.finishFileSend(offer)
        }.value
    }

    private func setFileProgress(_ value: Double) {
        fileTransferProgress = value
    }

    private func finishFileSend(_ offer: IBFileOffer) {
        broadcaster?.send(IBFileComplete(id: offer.id))
        fileTransferProgress = nil
    }

    func renamePairedMac(id: String, to name: String) {
        pairingStore.rename(id: id, to: name)
        refreshPairedMacs()
    }

    private func refreshPairedMacs() {
        pairedMacs = pairingStore.paired
        // The banner must follow the **effective** preference, not the armed
        // one: once the grace is spent the door is open to everyone, so a
        // banner still saying "waiting" would be the same class of lie as the
        // buttons that used to say "Safari" on a PC.
        let effective = pairingStore.effectivePreferred()
        if preferredMac != nil, effective == nil {
            let gaveUp = preferredMac
            Forensic.log("[gv] gaveUp set name=\(gaveUp?.name ?? "?") armedAt=\(String(describing: pairingStore.preferredArmedAt))")
            preferredGaveUp = gaveUp
            // Shown once, then it must go away on its own. It used to clear only
            // on the next `refreshPairedMacs` (i.e. when something dialled) or
            // the picker's Done button — so with nothing dialling it sat on the
            // main screen forever and could not be dismissed.
            preferredGaveUpAutoClear?.cancel()
            preferredGaveUpAutoClear = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.preferredGaveUp?.id == gaveUp?.id else { return }
                self.preferredGaveUp = nil
            }
        } else if preferredMac == nil, pairingStore.preferredId == nil {
            if preferredGaveUp != nil { Forensic.log("[gv] gaveUp cleared") }
            preferredGaveUp = nil
        }
        preferredMac = effective
        seenComputers = pairingStore.seen
        ensurePreferenceRefreshTimer()
    }

    /// Start the 1 s re-evaluation clock while there is a time-dependent banner
    /// to update, and let it retire once there is not.
    ///
    /// The grace is time-based, but every other reader of it (`effectivePreferred`)
    /// is only consulted when something happens. Nothing guarantees an event
    /// after the boundary, so the banner that says "switching to X…" had no way
    /// to notice the switch had failed — it stayed on the main screen until the
    /// user touched something. The clock is bounded to the banner's life
    /// (switching → gave-up → gone, ~40 s), not the 10-minute TTL.
    private func ensurePreferenceRefreshTimer() {
        guard preferredMac != nil || preferredGaveUp != nil else {
            preferenceRefreshTimer?.invalidate()
            preferenceRefreshTimer = nil
            return
        }
        guard preferenceRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPairedMacs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        preferenceRefreshTimer = timer
    }

    /// Arm a switch to a computer we've *seen* but may not have paired yet
    /// (a first-contact Windows PC has no `PairedMac` record). This is what
    /// makes "Choose a Computer" work when the current Mac won't release.
    func setPreferredComputer(id: String) {
        guard ownerMac?.id != id else { return }
        Forensic.log("[gv] arm preferred id=\(id.prefix(8)) owner=\(ownerMac?.id.prefix(8) ?? "nil")")
        // The name travels with the preference so the policy can name this
        // computer in `busy` even before it has ever been approved — without
        // it the door does not open and the switch silently reverts.
        pairingStore.setPreferred(id: id, name: nameForComputer(id: id))
        refreshPairedMacs()
        if ownerMac != nil {
            disconnectCurrentMac()
        }
        // Wake the chosen computer now so it dials at once — the phone cannot
        // open the data socket, so this short knock is how "tap to connect"
        // becomes immediate instead of waiting for the retry poll.
        knockComputer(id)
    }

    /// Dial a computer's advertised Bonjour endpoint once and drop it. The
    /// receiver treats an inbound connection on its knock port as "dial me back
    /// now". Fire-and-forget: the data session is still the computer dialing us.
    private func knockComputer(_ id: String) {
        guard let endpoint = computerEndpoints[id] else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        // `cancel()` is idempotent, so both the state handler and the timeout
        // can call it without coordination.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
        Forensic.log("[knock] dialed \(id.prefix(8))")
    }

    /// What the chosen computer's last attempt produced, for the waiting
    /// banner to explain itself with.
    func preferredOutcome(for id: String) -> AttemptOutcome? {
        pairingStore.lastOutcome(for: id)
    }

    /// When the current preference was armed, so the picker can time its
    /// wait-out to the grace period.
    var preferredArmedAt: Date? { pairingStore.preferredArmedAt }

    /// Forget the "gave up waiting for X" notice.
    func clearPreferredGaveUp() {
        preferredGaveUpAutoClear?.cancel()
        preferredGaveUpAutoClear = nil
        preferredGaveUp = nil
    }

    /// Called when the picker's wait-out timer fires: re-read the preference
    /// so a lapsed grace is noticed even though nothing knocked.
    func recheckPreferredMac() { refreshPairedMacs() }

    /// Drop computer rows the picker should no longer offer: identities a
    /// receiver has superseded, and machines long gone. Purely a display +
    /// bookkeeping fix — it never touches `paired`, so a live session and
    /// every approval survive untouched.
    func pruneSeenComputers() {
        if pairingStore.pruneStale(alsoKnown: Set(onlineComputers.map(\.id))) { refreshPairedMacs() }
    }

    /// The user-visible name we know for a computer id, preferring the live
    /// connection over the remembered list.
    private func nameForComputer(id: String) -> String? {
        if connectedMacId == id, let name = connectedMacName { return name }
        if let paired = pairingStore.paired.first(where: { $0.id == id }) { return paired.name }
        // Online (presence) before `seen`: a brand-new computer is in the
        // browse results before it has ever sent a `clientHello`, so arming a
        // switch to it must resolve a name from presence — otherwise
        // `setPreferred(id:name:nil)` leaves `preferred` nil and the tap does
        // nothing (it falls through to `busy(current)`).
        return ComputerRoster.name(for: id, online: onlineComputers, seen: pairingStore.seen)
    }

    /// E2E: a tap-on-notification needs a human finger on the phone, so this
    /// runs the *same* action the tap router runs, right after a relayed
    /// notification arrives — which lets the device e2e assert the Mac's
    /// `activated app` line. Only with REMOTECRAB_E2E_NOTIFY_TAP=1.
    private func runE2ENotifyTap(_ n: IBNotification) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.activateRelayedApp(named: n.app, windowTitle: n.windowTitle)
        }
    }

    /// E2E self-test: right after connect, emit a scripted touch-move
    /// burst plus one text event so the Mac side can prove CGEventPost
    /// injection really moves the cursor and types. Only runs when the
    /// app is launched with REMOTECRAB_E2E_INPUT=1.
    private func runE2EInputSequence() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            for _ in 0..<10 {
                self.sendTouch(TouchEvent(phase: .move, dx: 0.02, dy: 0.02))
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.sendKey(KeyEvent(action: .text, text: "RemoteCrab-e2e-OK"))
            Forensic.log("[e2e] input sequence sent")
        }
    }

    /// Force the injector's cursor to an ABSOLUTE known point —
    /// (0.3, 0.3) × Mac screen height. The Mac-side injector clamps
    /// the cursor to screen bounds, so a long up-left burst always
    /// lands at (0,0), and the fixed second burst lands exactly.
    private func e2eStageCursor() async {
        for _ in 0..<40 {
            self.sendTouch(TouchEvent(phase: .move, dx: -0.05, dy: -0.05))
            try? await Task.sleep(for: .milliseconds(15))
        }
        for _ in 0..<6 {
            self.sendTouch(TouchEvent(phase: .move, dx: 0.05, dy: 0.05))
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// E2E drag self-test (REMOTECRAB_E2E_DRAG=1): two scripted left
    /// drags. Before each, the cursor is staged at the ABSOLUTE point
    /// (0.3H, 0.3H) and a clipboard marker tells the Mac-side script to
    /// move the target window under it — the iPhone only sends relative
    /// moves, so the stage has to come to the cursor. Phase 1 drags the
    /// window by its title bar, phase 2 drag-selects text (⌘C check).
    private func runE2EDragSequence() {
        Task { @MainActor [weak self] in
            // The input sequence occupies grant+3…5s; stay clear of it.
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }

            // Phase 1 — window drag: +(0.12, 0.072) × Mac screen height.
            await self.e2eStageCursor()
            UIPasteboard.general.string = "e2e-drag1"
            self.sendClipboard()
            try? await Task.sleep(for: .seconds(2))
            self.sendTouch(TouchEvent(phase: .dragStart, dx: 0, dy: 0))
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(90))
                self.sendTouch(TouchEvent(phase: .move, dx: 0.02, dy: 0.012))
            }
            try? await Task.sleep(for: .milliseconds(90))
            self.sendTouch(TouchEvent(phase: .up, dx: 0, dy: 0))
            UIPasteboard.general.string = "e2e-drag1-done"
            self.sendClipboard()

            try? await Task.sleep(for: .seconds(2))

            // Phase 2 — text selection: −0.15 × Mac screen height on x.
            await self.e2eStageCursor()
            UIPasteboard.general.string = "e2e-drag2"
            self.sendClipboard()
            try? await Task.sleep(for: .seconds(2))
            self.sendTouch(TouchEvent(phase: .dragStart, dx: 0, dy: 0))
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(90))
                self.sendTouch(TouchEvent(phase: .move, dx: -0.025, dy: 0))
            }
            try? await Task.sleep(for: .milliseconds(90))
            self.sendTouch(TouchEvent(phase: .up, dx: 0, dy: 0))
            UIPasteboard.general.string = "e2e-drag2-done"
            self.sendClipboard()
            Forensic.log("[e2e] drag sequence sent")
        }
    }

    /// State changes for the granted owner connection.
    private func handleOwnerState(_ state: NWConnection.State, on conn: NWConnection) {
        guard connection === conn else { return }
        switch state {
        case .ready:
            break // grant() already set everything up.
        case .failed(let error):
            Self.log.error("connection failed: \(error, privacy: .public)")
            // `.cancelled` lands here too when it wasn't us who cancelled
            // (a local cancel makes `connection` nil first, and the guard
            // above drops the late callback), so it means the same thing:
            // the link is gone and the user should know.
            clearOwner(reason: .lost)
        case .cancelled:
            clearOwner(reason: .lost)
        default:
            break
        }
    }

    /// Why the session is being torn down.
    ///
    /// **This is deliberately the only input to the resulting
    /// `connectionState` transition.** Two call sites used to clear the
    /// owner *without* updating the state, and because `broadcaster` becomes
    /// nil there while `connectionState` stayed `.connected`, the UI kept
    /// showing a green "connected" over a dead link — so every app-switch
    /// tap was silently dropped with no feedback at all (that is the
    /// "switching apps doesn't work sometimes" report). Making the reason
    /// mandatory means a new call site cannot forget it.
    enum OwnerRelease {
        /// The peer went away on its own or the link broke. The user has to
        /// be told, and the Mac is (probably) reconnecting right now.
        case lost
        /// A deliberate local action — Stop, Disconnect, switching Macs.
        /// Not an error, so no red card.
        case disconnected
        /// A different Mac took over. `grant(_:…)` sets `.connected` a few
        /// lines later, so don't touch the state (it is still correct).
        case replaced
    }

    /// Drop the owner connection and everything derived from it.
    ///
    /// Pass `reason` — it is what decides the visible connection state (see
    /// `OwnerRelease`).
    /// Forget the computer we were talking to: its apps, its windows, its
    /// installable apps, and the images we rendered for them.
    ///
    /// One call, so "did we forget something?" is answerable by reading this
    /// list rather than by auditing eighteen fields. The four identity
    /// fields live in `PeerIdentity` because they once outlived their owner
    /// — the context sheet named the Mac's `访达` while Windows owned the
    /// session — and the image caches are here only because they are
    /// `UIImage`, which the core package cannot hold.
    private func clearPeerIdentity() {
        peer.clear()
        macAppIcons.removeAll()
        macWindowSnapshots.removeAll()
    }

    private func clearOwner(reason: OwnerRelease) {
        switch reason {
        case .lost:
            connectionState = .failed
            failureReason = .linkLost
        case .disconnected:
            connectionState = .idle
        case .replaced:
            break
        }
        stopOwnerWatchdog()
        // Every pending command is moot once the link is gone, and
        // `reportNoLink()` already says so. Letting them expire would
        // contradict that with N "your Mac app is too old" hints.
        commandLedger.clear()
        commandAppNames.removeAll()
        stopCommandExpiry()
        clearPeerIdentity()
        // Nothing will answer a list request made to the Mac that just left.
        installedAppsGate.reset()
        installedAppsPhase = installedAppsGate.current
        installedAppsAskedAt = nil
        stopInstalledAppsExpiry()
        broadcaster = nil
        audioEncoder?.stop()
        connection = nil
        ownerMac = nil
        connectedMacName = nil
        connectedMacId = nil
        connectedPlatform = "macos"
        peerCapabilities = []
        // The mirror can't survive a dropped link. Keep `screenOn` so it
        // resumes on reconnect (grant() calls syncScreen), but drop the
        // decoder state + target.
        screenActive = false
        screenPinnedWindowId = nil
        screenInfo = nil
        screenDecoder.reset()
        screenDisplayView.displayLayer.flushAndRemoveImage()
    }

    /// Release the session when the owner goes silent. The Mac pings
    /// every 2 s; 10 s of silence (5 missed pings) means the link is
    /// dead, so stop answering other Macs `busy` and let the next one in.
    private func startOwnerWatchdog() {
        stopOwnerWatchdog()
        lastInboundAt = Date()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkOwnerLiveness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ownerWatchdog = timer
        startLatencyProbes()
    }

    // MARK: - The approval slot

    /// Put a connection in the approval slot, or empty it.
    ///
    /// One writer for all four fields, so "a slot exists" and "a slot has a
    /// timestamp and a watchdog" cannot drift apart — the drift is what let a
    /// dead connection keep the slot and answer `busy` to every computer.
    private func setPending(connection: NWConnection?,
                            hello: IBClientHello?,
                            name: String?) {
        pendingConnection = connection
        pendingHello = hello
        pendingMacName = name
        pendingSince = connection == nil ? nil : Date()
        pendingWatchdog?.invalidate()
        pendingWatchdog = nil
        guard connection != nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPendingLiveness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingWatchdog = timer
    }

    private func clearPending() {
        setPending(connection: nil, hello: nil, name: nil)
    }

    /// Release an approval request nobody ever answered.
    ///
    /// Identity alone is not enough: `NWConnection` does not deliver
    /// `.cancelled` on every exit path, and a slot with no timer has no second
    /// line of defence. This is the pending half of what
    /// `checkOwnerLiveness` does for the owner.
    private func checkPendingLiveness() {
        guard let since = pendingSince, let conn = pendingConnection else { return }
        let waited = Date().timeIntervalSince(since)
        guard PendingSlotPolicy.isExpired(waited: waited) else { return }
        let name = pendingMacName ?? "another computer"
        Forensic.log("[hs] approval request from \(name) timed out after \(Int(waited))s — releasing the slot")
        clearPending()
        conn.cancel()
    }

    private func stopOwnerWatchdog() {
        ownerWatchdog?.invalidate()
        ownerWatchdog = nil
        stopLatencyProbes()
    }

    /// Probe the round trip every 3 s. A receiver too old to echo probes
    /// never answers; that is not an error, it just means `latencyMeasured`
    /// stays false and the UI shows nothing rather than guessing.
    private func startLatencyProbes() {
        stopLatencyProbes()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendLatencyProbe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        latencyProbeTimer = timer
    }

    private func stopLatencyProbes() {
        latencyProbeTimer?.invalidate()
        latencyProbeTimer = nil
        latencyProbe.reset()
        latencyTracker.reset()
    }

    private func sendLatencyProbe() {
        guard let broadcaster, broadcaster.isReady else { return }
        let micros = latencyProbe.makeProbe(now: Date())
        broadcaster.sendLatencyProbe(micros)
    }

    /// Raise the poor-link hint on the *transition* only.
    ///
    /// The tracker already reports a stable quality, so what is left is to
    /// not repeat ourselves: a link oscillating around the threshold would
    /// otherwise re-raise the same sentence every few seconds, which trains
    /// the user to ignore it. Announced once, retracted once, and re-armed
    /// only after the link is demonstrably good again.
    private func updateLatencyHint() {
        let poor = latencyTracker.isPoor
        guard poor != latencyHintShown else { return }
        latencyHintShown = poor
        if poor {
            showHint(IBLocale.Error.slowConnection)
        } else if transientHint == IBLocale.Error.slowConnection {
            transientHint = nil
            hintDismissTask?.cancel()
        }
    }

    private func checkOwnerLiveness() {
        guard connection != nil || ownerMac != nil else { return }
        let idle = Date().timeIntervalSince(lastInboundAt)
        guard idle > 10 else { return }
        Self.log.error("owner silent for \(Int(idle), privacy: .public)s — releasing the session")
        connection?.cancel()
        // `.lost`, not `.disconnected`: this is the path that used to leave
        // a green "connected" over a dropped link.
        Forensic.log("[link] owner silent — state now \(self.connectionState.debugName)")
        clearOwner(reason: .lost)
    }

    // MARK: - Receiving (Mac → iPhone control)

    private func startReceiving(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            if error != nil || isComplete {
                // The Mac went away. Clear the owner here rather than
                // hoping the state handler fires, so a stale `connection`
                // can't silently swallow the next Mac's clientHello.
                Task { @MainActor in
                    guard self.connection === connection else { return }
                    self.clearOwner(reason: .lost)
                }
                return
            }
            if self.connection != nil {
                self.startReceiving(from: connection)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        lastInboundAt = Date()
        for frame in parser.append(data) {
            switch frame.kind {
            case .featureControl:
                if let control = try? IBWire.decodeFeatureControl(frame) {
                    features.apply(control)
                }
            case .cameraCommand:
                if let command = try? IBWire.decodeCameraCommand(frame) {
                    switchCamera(to: command.position)
                }
            case .commandResult:
                if let result = try? IBWire.decodeCommandResult(frame) {
                    resolveCommand(result)
                }
            case .requestKeyframe:
                handleKeyframeRequest()
            case .speakerAudio:
                // Payload is PCM (see IBWire.encode(speakerAudio:)), so the
                // bytes go straight into the player — no decoder on this path.
                if let packet = try? IBWire.decodeSpeakerAudio(frame), packet.channels == 2 {
                    speakerPlayer.enqueue(packet.opusData)
                } else if let packet = try? IBWire.decodeSpeakerAudio(frame) {
                    Forensic.log("[audio] speaker frame ignored: channels=\(packet.channels) expected 2")
                }

            case .ping:
                // Either the echo of our own probe (a measurement) or the
                // Mac's own probe (echo it back so ITS round trip closes).
                // Getting this backwards would make the Mac compute the
                // offset between the two machine clocks.
                if frame.payload.count == 8,
                   let rtt = latencyProbe.roundTripMs(
                       ofEcho: IBWire.decodePing(frame), now: Date()) {
                    latencyTracker.record(millis: rtt)
                    if !latencyMeasured {
                        latencyMeasured = true
                        Forensic.log("[link] latency measured: \(rtt)ms")
                    }
                    if lastLatencyMs != latencyTracker.medianMs {
                        lastLatencyMs = latencyTracker.medianMs
                        updateLatencyHint()
                    }
                } else {
                    broadcaster?.sendPingEcho(frame.payload)
                }
            case .appList:
                if let list = try? IBWire.decodeAppList(frame) {
                    peer.install(apps: list.apps)
                    for app in list.apps where app.iconPNG != nil {
                        if let data = app.iconPNG, let image = UIImage(data: data) {
                            macAppIcons[app.id] = image
                        }
                    }
                }
            case .windowList:
                if let list = try? IBWire.decodeWindowList(frame) {
                    peer.install(windows: list.windows, canCapture: list.canCapture)
                    for window in list.windows where window.snapshotJPEG != nil {
                        if let data = window.snapshotJPEG, let image = UIImage(data: data) {
                            macWindowSnapshots[window.id] = image
                        }
                    }
                }
            case .installedApps:
                if let list = try? IBWire.decodeInstalledApps(frame) {
                    resolveInstalledApps(
                        list.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                        bytes: frame.payload.count, askedAt: installedAppsAskedAt)
                }
            case .screenSPS:
                screenDecoder.feed(IBNalFrame(kind: .sps, data: frame.payload, timestampMicros: 0))
            case .screenPPS:
                screenDecoder.feed(IBNalFrame(kind: .pps, data: frame.payload, timestampMicros: 0))
            case .screenVideo:
                screenDecoder.feed(IBNalFrame(kind: .video, data: frame.payload, timestampMicros: 0))
            case .screenInfo:
                if let info = try? IBWire.decodeScreenInfo(frame) {
                    let old = screenInfo
                    // A different window or resolution needs a fresh
                    // decoder session — SPS/PPS will follow.
                    let targetChanged = old?.windowId != info.windowId
                        || old?.pixelWidth != info.pixelWidth
                        || old?.pixelHeight != info.pixelHeight
                    screenInfo = info
                    if targetChanged {
                        // Reset the decoder so the new window's SPS/PPS
                        // rebuild it, but DO NOT flush the display layer:
                        // keeping the previous frame visible avoids a black
                        // flash while the Mac restarts capture on the new
                        // window.
                        screenDecoder.reset()
                    }
                }
            case .clipboardSet:
                if let clip = try? IBWire.decodeClipboard(frame) {
                    UIPasteboard.general.string = clip.text
                }
            case .notification:
                // Mac → iPhone relayed notification banner: always add it to
                // the in-app inbox; add a system banner too when allowed.
                if let n = try? IBWire.decodeNotification(frame) {
                    notificationStore.append(n)
                    // Marker only — never the notification's text (the whole
                    // point of the relay audit was that this half had no
                    // observable evidence at all).
                    Forensic.log("[notify] relayed notification received (app=\(n.app.count) chars, unread=\(notificationStore.unread))")
                    // Permission is asked here (in context) rather than at
                    // boot — the in-app inbox works without it, and the
                    // system banner appears as soon as the user allows.
                    requestNotificationAuthorizationIfNeeded()
                    localNotifier.post(n)
                    if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_NOTIFY_TAP"] == "1" {
                        runE2ENotifyTap(n)
                    }
                }
            case .fileAck:
                if let ack = try? IBWire.decodeFileAck(frame) {
                    lastFileAck = ack
                    if ack.status == .saved || ack.status == .error {
                        fileTransferProgress = nil
                    } else if ack.status == .progress {
                        fileTransferProgress = ack.receivedBytes > 0 ? fileTransferProgress : 0
                    }
                }
            default:
                break // all other kinds are iPhone → Mac only
            }
        }
    }

    // MARK: - Feature state

    private func handleFeaturesChanged(_ snapshot: FeatureStateSnapshot) {
        if snapshot.cameraOn && !wasCameraOn {
            // Fresh grace period so the watchdog doesn't fire while the
            // session spins back up after a deliberate camera toggle.
            lastVideoFrameAt = Date()
            hasProducedVideoFrame = false
        }
        wasCameraOn = snapshot.cameraOn
        broadcaster?.send(snapshot)
        syncAudioMode(snapshot)
        syncScreen()
    }

    /// React to `.screen` flipping — from the local top-bar toggle or a
    /// remote `featureControl` alike. Sends exactly one start/stop per
    /// actual change; the `screenActive` guard keeps this from re-entering
    /// the setter (which would loop).
    private func syncScreen() {
        guard let broadcaster else {
            screenActive = false
            return
        }
        // Hold-to-talk yields the mirror: the screen stream is the heaviest
        // CPU/GPU consumer on the phone, and running it under the speech
        // engine made dictation drop/skip characters. When voice is held we
        // stop the stream but KEEP the last decoded frame on screen (and the
        // user's pin); releasing restarts it.
        let want = features.screenOn && !features.voiceOn
        guard want != screenActive else { return }
        screenActive = want
        Forensic.log("[e2e] syncScreen(\(want)) voice=\(features.voiceOn)")
        if want {
            broadcaster.send(IBScreenControl(command: .start, maxPixel: preferredMaxPixel))
            // A yield stopped the stream, so the receiver starts fresh
            // following the frontmost app — re-apply the user's pin.
            if let pin = screenPinnedWindowId {
                broadcaster.send(IBScreenControl(command: .select, windowId: pin))
            }
        } else if features.screenOn {
            // Yielding to hold-to-talk: stop the expensive stream but KEEP
            // everything the surface needs to keep showing the last frame —
            // `ContentView` renders the mirror only while `screenInfo` is a
            // non-nil `.ok`, and clearing it (or the display layer) made the
            // mirror content vanish the moment voice was pressed.
            broadcaster.send(IBScreenControl(command: .stop))
        } else {
            // Genuinely off (not just yielding) — drop the stale frame and
            // the pinned-window preference too.
            broadcaster.send(IBScreenControl(command: .stop))
            screenDecoder.reset()
            screenInfo = nil
            screenPinnedWindowId = nil
            screenDisplayView.displayLayer.flushAndRemoveImage()
        }
    }

    /// The single place that applies `AudioModeArbiter` to the hardware.
    ///
    /// This replaces two copies of `micOn && !voiceOn` — one on the live
    /// feature-change path, one on the reconnect path — plus a third
    /// De Morgan complement in `applyKeepAlive`. Three expressions to keep in
    /// step is three chances to leave the microphone streaming while the
    /// phone plays the computer back, which is an echo the user hears and
    /// cannot diagnose.
    private func syncAudioMode(_ snapshot: FeatureStateSnapshot) {
        let mode = AudioModeArbiter.resolve(
            micOn: snapshot.micOn,
            voiceOn: snapshot.voiceOn,
            speakerOn: snapshot.speakerOn)
        syncAudioMode(mode)
    }

    private func syncAudioMode(_ snapshot: FeatureStore) {
        syncAudioMode(AudioModeArbiter.resolve(
            micOn: snapshot.micOn,
            voiceOn: snapshot.voiceOn,
            speakerOn: snapshot.speakerOn))
    }

    private func syncAudioMode(_ mode: AudioMode) {
        switch mode {
        case .microphone:
            if speakerPlayer.running { stopSpeakerPlayback(reason: "microphone took over") }
            syncMicrophone(true)
        case .speaker:
            // Stand the microphone down FIRST. BackgroundKeepAlive.stop()
            // must run before a `.playback` claim or its own `.playback`
            // session makes ours fail with '!pri' (see syncMicrophone).
            syncMicrophone(false)
            startSpeakerPlayback()
        case .voice:
            if speakerPlayer.running { stopSpeakerPlayback(reason: "hold-to-talk took over") }
            syncMicrophone(false)
        case .idle:
            if speakerPlayer.running { stopSpeakerPlayback(reason: nil) }
            syncMicrophone(false)
        }
        applyKeepAlive()
        Forensic.log("[audio] mode=\(mode) micWanted=\(AudioModeArbiter.wantsMicrophone(micOn: features.micOn, voiceOn: features.voiceOn, speakerOn: features.speakerOn)) speakerWanted=\(AudioModeArbiter.wantsSpeaker(micOn: features.micOn, voiceOn: features.voiceOn, speakerOn: features.speakerOn))")
    }

    /// Two independent toggles, so the UI can present them as two things
    /// rather than one three-way setting. Each stands the other down
    /// explicitly instead of leaning on the arbiter to break the tie: the
    /// STORED flags are what get sent to the computer, so leaving a stale
    /// `micOn` behind would show the microphone as live in the Mac's control
    /// panel while the phone was playing audio back at it.
    func toggleMicrophone() {
        setMicrophone(!features.micOn)
    }

    func toggleSpeaker() {
        setSpeaker(!features.speakerOn)
    }

    /// Sets the microphone and clears the speaker. Persisted, but NOT
    /// restored at launch: the microphone deliberately does not persist
    /// (restoring `micOn` would start recording the moment the app opens,
    /// which is a privacy surprise), and the speaker follows the same rule
    /// here even though it is not itself privacy-sensitive — a control that
    /// silently starts capturing on relaunch is the same surprise either way.
    func setMicrophone(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.micHabitKey)
        features.set(feature: .microphone, enabled: on)
        if on { features.set(feature: .speaker, enabled: false) }
        syncAudioMode(features)
    }

    /// Sets the speaker and clears the microphone. Persisted and RESTORED —
    /// this one uses the camera's pattern (`setCameraEnabled`), not the
    /// microphone's, because turning it on only asks the Mac to send audio
    /// and still requires a live session, so there is no surprise in
    /// resuming it.
    func setSpeaker(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.speakerHabitKey)
        features.set(feature: .speaker, enabled: on)
        if on { features.set(feature: .microphone, enabled: false) }
        syncAudioMode(features)
    }

    /// Still used by the e2e hook, which names a mode rather than a feature.
    func setAudioMode(_ mode: AudioMode) {
        switch mode {
        case .idle:
            features.set(feature: .speaker, enabled: false)
            features.set(feature: .microphone, enabled: false)
        case .microphone:
            setMicrophone(true)
        case .speaker:
            setSpeaker(true)
        case .voice:
            // Not user-selectable: hold-to-talk owns this while it lasts.
            break
        }
        syncAudioMode(features)
    }

    private static let micHabitKey = "remotecrab.ios.micOn"

    private func startSpeakerPlayback() {
        guard !speakerPlayer.running else { return }
        do {
            try speakerPlayer.start()
            Forensic.log("[audio] speaker playback started")
        } catch {
            // Never leave a glowing active state behind a failure (the same
            // rollback startVoice does): report it and stand the feature down.
            speakerStatus = error.localizedDescription
            Forensic.log("[audio] speaker playback FAILED: \(error.localizedDescription)")
            features.set(feature: .speaker, enabled: false)
            return
        }
        speakerStatus = nil
        // Prove the path works at the moment it turns on. Without this, a
        // phone on silent produces: toggle says on, the Mac's own speakers
        // go quiet (muteWhileTapped), and the user hears nothing at all.
        speakerPlayer.playConfirmationTone()
        speakerTickTask?.cancel()
        speakerTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self, self.speakerPlayer.running else { return }
                self.speakerPlayer.tick()
                self.speakerProgressTick += 1
                if self.speakerProgressTick % 50 == 0 {
                    // 20 ms x 50 = every second. This is the line that proves
                    // audio actually moved, rather than the control merely
                    // reporting itself as on.
                    Forensic.log("[e2e] speaker audio enqueued=\(self.speakerPlayer.packetsEnqueued) played=\(self.speakerPlayer.packetsScheduled) silence=\(self.speakerPlayer.silencePacketsScheduled) queued=\(self.speakerPlayer.queuedPackets) starved=\(self.speakerPlayer.starvedDrops) pcmRms=\(Int(self.speakerPlayer.receivedRms)) pktRms=\(Int(self.speakerPlayer.latestPacketRms)) pcmPeak=\(self.speakerPlayer.receivedPeak) \(self.speakerPlayer.playbackQualityText) envelope=\(self.speakerPlayer.envelopeText)")
                }
            }
        }
    }

    private func stopSpeakerPlayback(reason: String?) {
        speakerTickTask?.cancel()
        speakerTickTask = nil
        speakerPlayer.stop()
        speakerStatus = nil
        Forensic.log("[audio] speaker playback stopped\(reason.map { " (\($0))" } ?? "")")
    }

    private func syncMicrophone(_ enabled: Bool) {
        Forensic.log("[e2e] syncMicrophone(\(enabled)) broadcaster=\(broadcaster != nil)")
        if enabled {
            // Stop the keep-alive but LEAVE THE SESSION ACTIVE
            // (`deactivateSession: false`): the mic reconfigures the shared
            // session to `.record` itself, and deactivating here then
            // reactivating in the same runloop turn makes the mic's
            // `setActive(true)` fail with 561017449 ("Session activation
            // failed") — measured on device, exactly what
            // `BackgroundKeepAlive.stop` documents. (This used to pass the
            // default `true`; the old comment cited `.playAndRecord`, which
            // the mic no longer uses.)
            BackgroundKeepAlive.shared.stop(deactivateSession: false)
            if audioEncoder == nil {
                audioEncoder = MicrophoneEncoder()
            }
            if let broadcaster { audioEncoder?.start(broadcaster: broadcaster) }
        } else {
            audioEncoder?.stop()
            applyKeepAlive()
        }
    }

    /// Hold the app open in the background, unless a record session
    /// (mic/voice) is already doing so.
    private func applyKeepAlive() {
        // NOT `micOn || voiceOn`: that expression is the De Morgan complement
        // of the one in syncMicrophone, and the speaker mode sits between
        // them — a playback-only mode must not read as "recording", or the
        // keep-alive starts its own `.playback` session and races the
        // speaker player's for the one AVAudioSession.
        let recording = AudioModeArbiter.isRecording(
            micOn: features.micOn,
            voiceOn: features.voiceOn,
            speakerOn: features.speakerOn)
        if isStreaming && !recording {
            BackgroundKeepAlive.shared.start()
        } else {
            BackgroundKeepAlive.shared.stop()
        }
    }

    // MARK: - Sending

    private func sendMetadata(on connection: NWConnection) {
        do {
            let encoded = try IBWire.encode(metadata: metadata)
            connection.send(content: encoded, completion: .contentProcessed { error in
                if let error {
                    Self.log.error("metadata send error: \(error, privacy: .public)")
                }
            })
        } catch {
            Self.log.error("metadata encode error: \(error, privacy: .public)")
        }
    }

    private var e2eFrameCount = 0
    private var e2eFrameBytes = 0
    private var e2eDropCount = 0
    private var lastSPSFrame: IBNalFrame?
    private var lastPPSFrame: IBNalFrame?

    private func handleEncodedFrame(_ frame: IBNalFrame) {
        switch frame.kind {
        case .sps: lastSPSFrame = frame
        case .pps: lastPPSFrame = frame
        default: break
        }
        guard features.cameraOn else { return }
        hasProducedVideoFrame = true
        guard let connection, connection.state == .ready else { return }
        lastVideoFrameAt = Date()
        let encoded = IBWire.encode(frame: frame)
        connection.send(content: encoded, completion: .contentProcessed { [weak self] error in
            if let error, let self {
                Self.forensic("video send error after \(self.e2eSendOKCount) ok frames: \(error)")
            }
        })
        e2eSendOKCount += 1
        if e2eSendOKCount % 300 == 0 {
            Self.forensic("frames sent to Mac: \(e2eSendOKCount)")
        }
        if ProcessInfo.processInfo.environment["REMOTECRAB_AUTOSTREAM"] == "1" {
            e2eFrameCount += 1
            e2eFrameBytes += encoded.count
            if e2eFrameCount % 60 == 0 {
                Forensic.log("[e2e] video frames sent: \(e2eFrameCount), bytes: \(e2eFrameBytes)")
            }
        }
    }

    private var e2eSendOKCount = 0
}

extension IBStreamMetadata {
    @MainActor
    static func defaultConfig() -> IBStreamMetadata {
        IBStreamMetadata(
            deviceName: UIDevice.current.name,
            width: 1920,
            height: 1080,
            fps: 30,
            bitrateBps: 4_000_000
        )
    }
}