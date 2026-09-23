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

    // Multi-Mac pairing surface for the UI.
    /// Every Mac the user has approved (settings → Paired Macs).
    @Published private(set) var pairedMacs: [PairedMac] = []
    /// Name of a Mac waiting for the user's approval, if any.
    @Published private(set) var pendingMacName: String?
    /// The Mac the user picked in the Mac picker — it takes over on its
    /// next connect while others are answered "busy".
    @Published private(set) var preferredMac: PairedMac?
    /// Name of the Mac currently owning the session, if any.
    @Published private(set) var connectedMacName: String?
    /// Stable id of the owning Mac (matches `PairedMac.id`).
    @Published private(set) var connectedMacId: String?
    /// Running apps on the Mac, for the app switcher.
    @Published private(set) var macApps: [IBAppInfo] = []
    /// Frontmost Mac app, from the latest pushed appList (0x0C).
    var frontmostMacApp: IBAppInfo? { macApps.first(where: { $0.isActive }) }

    /// Presents the context-shortcut sheet (observed by ContentView).
    @Published var showContextSheet = false
    /// Decoded app icons keyed by app id. Merged from `appList` frames
    /// that carry `iconPNG`; kept across refreshes because background
    /// publishes omit icons (only an explicit switcher request fetches
    /// them).
    @Published private(set) var macAppIcons: [String: UIImage] = [:]
    /// Mac windows for the full-screen window picker, front-to-back.
    @Published private(set) var macWindows: [IBWindowInfo] = []
    /// False when the Mac lacks Screen Recording, so `macWindows` holds
    /// one app-level entry per app instead of real windows.
    @Published private(set) var windowsCanCapture = false
    /// Decoded window snapshots keyed by `IBWindowInfo.id`. Kept across
    /// refreshes so a background refresh without pixels doesn't blank the
    /// cards.
    @Published private(set) var macWindowSnapshots: [String: UIImage] = [:]
    /// Fixed listening port (for manual "connect by IP" when Bonjour is
    /// blocked) + this device's WiFi address, shown in the connection sheet.
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var localAddress: String?
    /// 0…1 while sending a file to the Mac; nil when idle.
    @Published private(set) var fileTransferProgress: Double?
    /// Latest transfer ack from the Mac.
    @Published private(set) var lastFileAck: IBFileAck?

    let captureSession = AVCaptureSession()

    enum ConnectionState: Equatable {
        case idle
        case starting
        case connected
        case failed
    }

    // MARK: - Private state

    private var encoder = H264Encoder()
    private var listener: NWListener?
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
    /// Watchdog that releases a silent owner (see `lastInboundAt`).
    private var ownerWatchdog: Timer?
    /// Connection currently awaiting a `clientHello` (not yet granted).
    private var candidate: NWConnection?
    private var candidateParser: IBWire.Parser?
    /// Connection whose `clientHello` is waiting on the user's approval.
    private var pendingConnection: NWConnection?
    private var pendingHello: IBClientHello?
    /// Identifies the in-flight candidate read so late callbacks from a
    /// superseded connection can't admit the wrong Mac.
    private var handshakeToken: UUID?
    private var handshakeTask: Task<Void, Never>?

    let pairingStore = MacPairingStore()

    /// Shared broadcaster for touch / key / audio events. Created when
    /// a Mac connects and torn down when the connection drops.
    private(set) var broadcaster: IBEventBroadcaster?

    private(set) var audioEncoder: MicrophoneEncoder?

    /// Single source of truth for capability state. Bound by the UI
    /// and mutated by remote FeatureControl frames alike.
    let features = FeatureStore()

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
        Self.forensic("startIfNeeded begin")
        Forensic.log("[e2e] startIfNeeded begin")

        features.onChange = { [weak self] snapshot in
            self?.handleFeaturesChanged(snapshot)
        }
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
                                         bitrate: bitrateFor(width: dims.width, height: dims.height, fps: currentFps))
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
                                        bitrateBps: bitrateFor(width: dims.width, height: dims.height, fps: currentFps))
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
    /// Interim results are typed as they arrive (word-by-word) so a long
    /// hold can't lose a paragraph if a session dies; the delta is
    /// computed against what we've already typed. Also doubles as a tiny
    /// voice-command surface: "open X" / "切换到 X" activates a running
    /// Mac app, "改写…" transforms the Mac's selection.
    private var voiceTypedText = ""
    /// The previous full interim text, so we can tell which prefix is stable.
    private var voiceLastFull = ""

    /// Interim transcription (full text so far). Type only the part that
    /// has been STABLE across the last two updates: the tail is still being
    /// revised by the recognizer (punctuation, word fixes), and typing it
    /// would duplicate when it changes. The remaining tail is typed by
    /// `finishVoiceText`. Never deletes.
    func updateVoiceText(_ full: String) {
        // Don't type live while the utterance looks like a command;
        // wait for the final so the command words never hit the Mac.
        guard !looksLikeVoiceCommand(full) else { return }
        let stable = Self.commonPrefix(full, voiceLastFull)
        voiceLastFull = full
        guard stable.count > voiceTypedText.count else { return }
        let delta = String(stable.dropFirst(voiceTypedText.count))
        if !delta.isEmpty { broadcaster?.send(KeyEvent(action: .text, text: delta)) }
        voiceTypedText = stable
    }

    /// Final transcription for the hold.
    func finishVoiceText(_ final: String) {
        if handleVoiceCommand(final) {
            // Deliberately do NOT erase what was typed: a long dictation
            // that merely starts with a command-like word was being
            // mis-detected here and the whole paragraph got backspaced
            // away. A stray prefix word is far better than data loss.
            voiceTypedText = ""
            voiceLastFull = ""
            return
        }
        // Type whatever is left after the already-typed stable prefix.
        let common = Self.commonPrefix(final, voiceTypedText)
        let tail = String(final.dropFirst(common.count))
        if !tail.isEmpty { broadcaster?.send(KeyEvent(action: .text, text: tail)) }
        voiceTypedText = ""
        voiceLastFull = ""
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
            if let app = macApps.first(where: {
                $0.name.lowercased().contains(target) || $0.id.lowercased().contains(target)
            }) {
                Self.log.info("voice command → activate \(app.name, privacy: .public)")
                activateMacApp(id: app.id)
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

    func startStreaming() async {
        Forensic.log("[e2e] startStreaming called, isStreaming=\(isStreaming)")
        guard !isStreaming else { return }
        connectionState = .starting
        do {
            try startListener()
            Forensic.log("[e2e] listener started OK")
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
        }
    }

    func stopStreaming() {
        BackgroundKeepAlive.shared.stop()
        listener?.cancel()
        listener = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate?.cancel()
        candidate = nil
        candidateParser = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil
        connection?.cancel()
        clearOwner()
        isStreaming = false
        connectionState = .idle
        parser.reset()
        stopVideoWatchdog()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Called on every return to the foreground (scenePhase == .active).
    /// iOS suspends the Bonjour listener while the app is backgrounded,
    /// so a previously-streaming app comes back with a dead
    /// advertisement and usually a reset TCP link while `isStreaming`
    /// still reads true. Recreate the listener to force the service to
    /// re-register; the Mac side auto-reconnects once we're visible.
    func handleDidBecomeActive() {
        guard isStreaming else { return }
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
        let config = videoDims(resolution: currentResolution, portrait: encoderIsPortrait)
        captureSession.beginConfiguration()
        captureSession.sessionPreset = config.preset
        captureSession.commitConfiguration()

        let newEncoder = H264Encoder(width: Int32(config.width), height: Int32(config.height),
                                     fps: currentFps,
                                     bitrate: bitrateFor(width: config.width, height: config.height, fps: currentFps))
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
                                        bitrateBps: bitrateFor(width: config.width, height: config.height, fps: currentFps))
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

    /// ~0.1 bpp real-time talk-band heuristic, clamped to [1, 12] Mbps.
    private func bitrateFor(width: Int, height: Int, fps: Int) -> Int {
        let raw = Int(Double(width * height * fps) * 0.1)
        return min(max(raw, 1_000_000), 12_000_000)
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
        captureSession.sessionPreset = preset

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
        // Read the hello before deciding anything: a Mac that reconnected
        // after its socket dropped must be allowed to reclaim its own
        // session, and we can only tell that from the hello's id.
        if let pendingConnection, pendingConnection !== newConnection {
            pendingConnection.cancel()
        }
        pendingConnection = nil
        pendingHello = nil
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
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.handshakeToken == token,
                  self.connection == nil, self.pendingConnection == nil else { return }
            Self.log.info("clientHello timeout — admitting legacy Mac")
            self.sendSessionReply(IBSessionReply(result: .accepted), on: conn)
            self.grant(connection: conn, mac: nil)
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
        if let existing = connection, existing !== conn {
            // A different Mac while someone owns the session keeps the
            // owner. But the SAME Mac reconnecting (its old socket died,
            // possibly without us noticing) takes its session back — and
            // a dead-but-still-"ready" owner never blocks anyone.
            let sameMac = (connectedMacId != nil && connectedMacId == hello.id)
            if existing.state == .ready && !sameMac {
                replyBusy(on: conn, ownerName: connectedMacName ?? "another Mac")
                return
            }
            existing.cancel()
            clearOwner()
        }
        // A second Mac showed up while the first was mid-handshake.
        if pendingConnection != nil && pendingConnection !== conn {
            replyBusy(on: conn, ownerName: pendingMacName ?? "another Mac")
            return
        }
        let decision = PairingPolicy.decide(hello: hello, paired: pairingStore.paired, owner: nil,
                                            preferred: pairingStore.preferred)
        Self.log.info("clientHello \(hello.name, privacy: .public) -> \(String(describing: decision), privacy: .public)")

        switch decision {
        case .accept:
            guard let mac = pairingStore.paired.first(where: { $0.id == hello.id }) else {
                // Shouldn't happen, but never strand the Mac.
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                pendingConnection = conn
                pendingHello = hello
                pendingMacName = hello.name
                return
            }
            sendSessionReply(IBSessionReply(result: .accepted, token: mac.token), on: conn)
            grant(connection: conn, mac: mac)
        case .pending:
            // Headless e2e: auto-approve so a run needs no phone tap.
            if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_AUTOPAIR"] == "1" {
                sendSessionReply(IBSessionReply(result: .pending), on: conn)
                pendingConnection = conn
                pendingHello = hello
                pendingMacName = hello.name
                approvePendingMac()
                return
            }
            sendSessionReply(IBSessionReply(result: .pending), on: conn)
            pendingConnection = conn
            pendingHello = hello
            pendingMacName = hello.name
        case .busy(let ownerName):
            replyBusy(on: conn, ownerName: ownerName)
        }
    }

    /// Promote a connection to the session owner and start streaming.
    private func grant(connection conn: NWConnection, mac: PairedMac?) {
        handshakeTask?.cancel()
        handshakeTask = nil
        handshakeToken = nil
        candidate = nil
        candidateParser = nil
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil

        // The preferred Mac arrived — the switch is done, open the door.
        if let mac, mac.id == pairingStore.preferredId {
            pairingStore.clearPreferred()
            refreshPairedMacs()
        }

        ownerMac = mac
        connection = conn
        connectedMacName = mac?.name ?? "Mac (legacy)"
        connectedMacId = mac?.id
        connectionState = .connected
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
        syncMicrophone(features.micOn && !features.voiceOn)
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
        // E2E: exercise the voice pipeline without real speech —
        // REMOTECRAB_E2E_VOICE=1 simulates "say → pause (recognizer resets
        // and shrinks) → keep talking", which used to backspace away the
        // earlier words. The Mac log must show the full text and NO
        // backspace from the pause.
        if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_VOICE"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.updateVoiceText("前面输入的内容")   // first utterance
                try? await Task.sleep(for: .milliseconds(400))
                self?.updateVoiceText("前面输入的内容")   // stable -> typed
                try? await Task.sleep(for: .milliseconds(400))
                self?.updateVoiceText("新词")             // LONG PAUSE: recognizer reset (shrank)
                try? await Task.sleep(for: .milliseconds(400))
                self?.finishVoiceText("新词")
                try? await Task.sleep(for: .milliseconds(300))
                // And a final that LOOKS like a command — must not erase.
                self?.updateVoiceText("变成大写")
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
            candidate = nil
            candidateParser = nil
            if pendingConnection === candidate {
                pendingConnection = nil
                pendingHello = nil
                pendingMacName = nil
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
        refreshPairedMacs()
        sendSessionReply(IBSessionReply(result: .accepted, token: mac.token), on: conn)
        grant(connection: conn, mac: mac)
    }

    /// Deny the waiting Mac and close its connection.
    func denyPendingMac() {
        guard let conn = pendingConnection else { return }
        sendSessionReply(IBSessionReply(result: .denied), on: conn)
        pendingConnection = nil
        pendingHello = nil
        pendingMacName = nil
        queue.asyncAfter(deadline: .now() + 0.4) { conn.cancel() }
    }

    /// Drop the current owner (settings / connected banner).
    func disconnectCurrentMac() {
        connection?.cancel()
        clearOwner()
    }

    func forgetPairedMac(id: String) {
        pairingStore.forget(id: id)
        refreshPairedMacs()
    }

    /// Mark a paired Mac as the one this iPhone should serve. If a
    /// different Mac currently owns the session it is dropped; until
    /// the chosen Mac reconnects, every other Mac is answered "busy".
    func setPreferredMac(id: String) {
        // Already serving this Mac — a preference would just hold the
        // door against everyone else until it expires.
        guard ownerMac?.id != id else { return }
        pairingStore.setPreferred(id: id)
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

    // MARK: - App switcher

    /// Ask the Mac for a fresh running-app list.
    func requestMacApps() {
        broadcaster?.send(IBAppListRequest())
    }

    /// Ask the Mac for a fresh window list (window picker).
    func requestMacWindows() {
        broadcaster?.send(IBWindowListRequest())
    }

    /// Bring a Mac app to the front, and optionally raise one specific
    /// window of it (matches the picked window card).
    func activateMacApp(id: String, windowTitle: String? = nil) {
        broadcaster?.send(IBActivateApp(id: id, windowTitle: windowTitle))
    }

    /// Quit a Mac app. Graceful by default (the app may show a save sheet
    /// on the Mac); `force` terminates immediately and can lose work.
    func quitMacApp(id: String, force: Bool) {
        broadcaster?.send(IBQuitApp(id: id, force: force))
        // Optimistic: drop the app's cards from the open window picker
        // immediately. The Mac republishes the list right after the quit
        // and reconciles — if a graceful quit is blocked by an invisible
        // save prompt, the card simply comes back.
        macWindows.removeAll { $0.appId == id }
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
        preferredMac = pairingStore.preferred
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
            connectionState = .failed
            clearOwner()
        case .cancelled:
            connectionState = .idle
            clearOwner()
        default:
            break
        }
    }

    private func clearOwner() {
        stopOwnerWatchdog()
        broadcaster = nil
        audioEncoder?.stop()
        connection = nil
        ownerMac = nil
        connectedMacName = nil
        connectedMacId = nil
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
    }

    private func stopOwnerWatchdog() {
        ownerWatchdog?.invalidate()
        ownerWatchdog = nil
    }

    private func checkOwnerLiveness() {
        guard connection != nil || ownerMac != nil else { return }
        let idle = Date().timeIntervalSince(lastInboundAt)
        guard idle > 10 else { return }
        Self.log.error("owner silent for \(Int(idle), privacy: .public)s — releasing the session")
        connection?.cancel()
        clearOwner()
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
                    self.connectionState = .idle
                    self.clearOwner()
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
            case .ping:
                broadcaster?.sendPingEcho(frame.payload)
            case .appList:
                if let list = try? IBWire.decodeAppList(frame) {
                    macApps = list.apps
                    for app in list.apps where app.iconPNG != nil {
                        if let data = app.iconPNG, let image = UIImage(data: data) {
                            macAppIcons[app.id] = image
                        }
                    }
                }
            case .windowList:
                if let list = try? IBWire.decodeWindowList(frame) {
                    macWindows = list.windows
                    windowsCanCapture = list.canCapture
                    for window in list.windows where window.snapshotJPEG != nil {
                        if let data = window.snapshotJPEG, let image = UIImage(data: data) {
                            macWindowSnapshots[window.id] = image
                        }
                    }
                }
            case .clipboardSet:
                if let clip = try? IBWire.decodeClipboard(frame) {
                    UIPasteboard.general.string = clip.text
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
        syncMicrophone(snapshot.micOn && !snapshot.voiceOn)
    }

    private func syncMicrophone(_ enabled: Bool) {
        Forensic.log("[e2e] syncMicrophone(\(enabled)) broadcaster=\(broadcaster != nil)")
        if enabled {
            // A live record session already keeps iOS from suspending us,
            // so the silent keep-alive must stand down completely before
            // the mic reconfigures the session — leaving it active in
            // `.playback` makes the mic's `.playAndRecord` switch fail
            // with '!pri' (incompatible category while active).
            BackgroundKeepAlive.shared.stop()
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
        let recording = features.micOn || features.voiceOn
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