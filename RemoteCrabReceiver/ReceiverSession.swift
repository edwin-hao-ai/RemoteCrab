import AppKit
import Foundation
import Network
import os
import SwiftUI
import VideoToolbox
import ApplicationServices
import RemoteCrabCore

/// The Mac-side counterpart to iOS `CaptureEngine`. Browses for the
/// Bonjour service, opens the first connection it sees, decodes H.264
/// frames via VideoToolbox, dispatches touch / key / audio events
/// to their respective handlers, and republishes the latest decoded
/// frame for the SwiftUI preview view.
@MainActor
final class ReceiverSession: ObservableObject {

    /// App-lifetime singleton: the receiver is a menu-bar app with exactly
    /// one session, and the updater needs a stable reference to read idle
    /// state without depending on any view's lifetime.
    static let shared = ReceiverSession()

    /// The Core policy works on a platform-free mirror of the state, because
    /// `ReceiverSession` is macOS-only and cannot be imported from the package.
    /// A new case here must be added there too, or this will not compile —
    /// which is the intended alarm rather than a silent default.
    private var stateKind: ReceiverStateKind {
        switch state {
        case .searching: return .searching
        case .connecting: return .connecting
        case .handshaking: return .handshaking
        case .awaitingApproval: return .awaitingApproval
        case .streaming: return .streaming
        case .error: return .error
        }
    }

    /// Raise a desktop notification the first time this run needs a tap on the
    /// phone.
    ///
    /// The phone's approval card is a 5-inch screen you may not be holding, and
    /// the Mac's only cue is a menu-bar row. Without this, the run sits in
    /// `awaitingApproval` until something times out and the visible symptom is
    /// "it didn't connect" with no hint that a tap was the missing step.
    /// Drop the alert once the wait resolves, so a solved problem does not leave
    /// a notification lying around claiming otherwise.
    private func clearApprovalNoticeIfResolved(previous: State) {
        guard ApprovalNotificationPolicy.shouldResetAfterExit(
            previous: stateKind(of: previous), next: stateKind) else { return }
        notifiedAboutCurrentWait = false
        ApprovalNotifier.clear()
    }

    private func noteApprovalNeededIfFirstTime(previous: State) {
        let decision = ApprovalNotificationPolicy.shouldNotify(
            previous: stateKind(of: previous),
            next: stateKind,
            isFirstEntryThisSession: !didNotifyAboutApprovalThisRun,
            alreadyNotifiedForThisWait: notifiedAboutCurrentWait)
        guard decision else { return }
        didNotifyAboutApprovalThisRun = true
        notifiedAboutCurrentWait = true
        let phone = currentPhoneName() ?? ""
        let body = phone.isEmpty
            ? IBLocale.Connection.awaitingApprovalGeneric
            : String(format: IBLocale.Connection.awaitingApprovalNamed, phone)
        Self.log.info("notifying: the iPhone is waiting for approval")
        ApprovalNotifier.post(title: IBLocale.Connection.awaitingApprovalTitle, body: body)
    }

    private func stateKind(of s: State) -> ReceiverStateKind {
        switch s {
        case .searching: return .searching
        case .connecting: return .connecting
        case .handshaking: return .handshaking
        case .awaitingApproval: return .awaitingApproval
        case .streaming: return .streaming
        case .error: return .error
        }
    }

    enum State: Equatable {
        case searching
        case connecting(name: String)
        /// TCP is up; we've sent our `clientHello` and await the iPhone's
        /// ownership decision.
        case handshaking(name: String)
        /// The iPhone is showing an approval prompt — do not retry.
        case awaitingApproval(name: String)
        case streaming(name: String, latencyMs: Int)
        case error(String)
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var metadata: IBStreamMetadata?
    @Published private(set) var discovered: [DiscoveredPhone] = []

    /// The most recent decoded frame as a `CGImage` ready for display.
    @Published private(set) var latestFrame: CGImage?
    private var videoFrameCount = 0
    private var audioPacketCount = 0
    /// Lazily created on the first Opus packet; nil-decodable packets
    /// (legacy senders) never touch it.
    private var opusDecoder: IBOpusDecoder?
    private var opusDropCount = 0
    private var touchEventCount = 0
    private var keyEventCount = 0

    /// Latest feature-state snapshot from the iPhone. nil until the
    /// first `featureState` frame arrives (older iOS builds never
    /// send one — the UI must treat nil as "remote control unavailable").
    @Published private(set) var featureState: FeatureStateSnapshot?

    /// Why the speaker path is not running, in words the user can act on.
    /// `nil` means "not on, nothing to report" — a status surface that has
    /// to distinguish "fine" from "broken" from "off" cannot be a Bool.
    @Published private(set) var speakerStatus: String?

    /// Live proof the tap is actually receiving audio, for the e2e run and
    /// the test window. A feature that reports itself as on while capturing
    /// silence is worse than one that fails.
    @Published private(set) var speakerCapturedFrames: UInt64 = 0
    @Published private(set) var speakerDroppedFrames: UInt64 = 0

    /// The Mac is the SENDER for this feature, so it reacts to the phone's
    /// `featureState` echo rather than to `featureControl` — the same
    /// one-way loop the microphone already uses.
    private let speakerTap = SystemAudioTap()
    private var speakerPumpTask: Task<Void, Never>?
    private var lastLevelReportAt: Double = -1
    private var packetBytes = 0

    /// Running regular apps published to the iPhone's app switcher.
    @Published private(set) var macApps: [IBAppInfo] = []
    /// Rasterized icon PNGs keyed by app id (bundle id or `pid:<n>`).
    /// Filled lazily when the iPhone asks for icons; icons never change
    /// while an app is running, so this is process-lifetime cached.
    private var iconCache: [String: Data] = [:]
    /// True once we've popped the Screen Recording prompt this run, so a
    /// window refresh doesn't nag for permission every time.
    private var didRequestScreenRecording = false

    /// When the iPhone last asked for the window list — lets a background
    /// event (e.g. an app quitting) refresh the picker only while it's
    /// likely open, instead of capturing every window on every change.
    private var lastWindowListRequestAt: Date?

    /// A launch and the activation that follows it are one change, not two,
    /// and each window rebuild costs a JPEG per window. This collapses the
    /// pair and waits for the app to actually reach the front — otherwise
    /// the card is built from a process that has no window yet, which is
    /// exactly the "I opened it and it isn't there" complaint.
    private var windowChangeCoalescer = IBChangeCoalescer()
    private var windowChangeTimer: Timer?
    /// Whether the pending refresh belongs to a launch, i.e. may still be
    /// pushed back by that launch's `didActivateApplication`.
    private var windowChangeExpectsActivation = false

    /// When the last ping echo came back — the ping loop treats 8 s of
    /// silence as a dead link (see `startPingLoop`).
    private var lastPongAt: Date?

    /// Our own ping cadence, and the discriminator that keeps the phone's
    /// probes from being measured as our own echoes (see `IBPingProbe`).
    private var pingProbe = IBPingProbe()
    private var latencyTracker = IBLatencyTracker(window: 30)

    /// Mac → iPhone app-screen mirror. nil until the iPhone sends
    /// `screenControl(.start)`; torn down on `.stop` and on disconnect.
    private var screenStreamer: ScreenStreamer?
    /// The extra display created for "extend" mode, torn down with the
    /// mirror / connection.
    private var virtualDisplay: VirtualDisplay?
    /// Last geometry the mirror published, used to translate `screenInput`
    /// coordinates back to global cursor positions.
    private var lastScreenInfo: IBScreenInfo?

    /// Best-effort capture of macOS notification banners, active only while
    /// the session is live and `remotecrab.mac.notifyRelay` is on.
    private var notificationCapture: NotificationCapture?
    /// Reused Mac → iPhone event broadcaster (currently the notification
    /// relay). Created when the session is accepted, cleared on disconnect.
    private var broadcaster: IBEventBroadcaster?

    /// Last file received from the iPhone (menu bar → Show in Finder).
    @Published private(set) var lastReceivedFileURL: URL?

    /// True while recording the live stream to disk.
    @Published private(set) var isRecording = false
    let recorder = StreamRecorder()
    /// Feeds PCM to the optional virtual-microphone HAL driver.
    private let micRing = MicRingWriter()

    // MARK: - Connection test mirrors (read-only for the UI)

    /// Rolling tail of everything typed from the iPhone keyboard,
    /// truncated to the most recent 200 characters.
    @Published private(set) var typedText: String = ""
    /// The most recent `.down` / `.text` key event.
    @Published private(set) var lastKey: KeyEvent?
    /// The most recent touch event, mirrored for the test-board view.
    @Published private(set) var touchVisual: TouchVisual?
    /// Rolling trail of recent touch events (~1-2 s at pan speed) so
    /// the test board can render swipe trails and press marks.
    @Published private(set) var touchTrail: [TouchVisual] = []
    /// Live microphone RMS level (0..1), ~10 Hz from `AudioPlayer`.
    @Published private(set) var micLevel: Float = 0
    /// Mac-speaker monitoring of the iPhone mic. Defaults off: playing
    /// the mic back through speakers next to the live iPhone is an
    /// acoustic feedback loop (the "echo" users hear). Level metering
    /// keeps working while muted.
    @Published var monitoringMuted = true {
        didSet { audioPlayer.setMuted(monitoringMuted) }
    }
    /// The 30 most recent ping round-trip times, oldest first.
    @Published private(set) var latencyHistory: [Int] = []

    private var pingTimer: Timer?
    private static let log = Logger(subsystem: "com.remotecrab", category: "receiver")

    let browser = BonjourBrowser()
    let decoder = H264Decoder()
    let parser = IBWire.Parser()

    /// Pushes decoded frames into the camera extension's CMIO sink
    /// stream so Zoom / FaceTime / Photo Booth can use the iPhone as a
    /// webcam. No-ops until the extension is active.
    let cameraSinkFeeder = CameraSinkFeeder()

    /// Where `TouchEvent` / `KeyEvent` get posted. Defaults to the real
    /// `CGEventInjector` so iPhone gestures drive the Mac cursor; tests
    /// swap in a `RecordingInputInjector`. UI mirroring for the test
    /// window happens in `handleInbound` before injection, so it works
    /// regardless of which injector is installed.
    var inputInjector: InputInjector = CGEventInjector()

    /// Where `AudioPacket` get played through Mac speakers.
    let audioPlayer = AudioPlayer()

    private var connection: NWConnection?
    /// Display name of the phone we're connected to (from Bonjour),
    /// kept so the UI never shows a raw IP:port endpoint string.
    private var connectedPhoneName: String?

    // MARK: - Multi-Mac pairing (client side)

    /// Stable identity for this Mac, persisted across launches.
    private var macId: String = ReceiverSession.loadMacId()
    private var macName: String = ReceiverSession.loadMacName()
    /// Announces this Mac on `_remotecrab-computer._tcp` so the iPhone can show
    /// which computers are online right now.
    private var presenceAdvertiser: PresenceAdvertiser?
    /// iPhone-name → pairing token, persisted across launches. Lets the
    /// iPhone recognise this Mac without re-prompting.
    private var tokenStore: [String: String] = ReceiverSession.loadTokens()
    /// Names of iPhones this Mac has paired with (token store keys),
    /// surfaced for Preferences → Paired iPhones.
    @Published private(set) var pairedPhones: [String] = []
    /// Bonjour name of the phone we're handshaking with (token key).
    private var currentTokenKey: String?
    /// True only after the iPhone's `sessionReply` accepted us.
    private var sessionGranted = false
    /// True while a Mac/iPhone session is owned. Read by `UpdaterController`
    /// to gate silent installs (an active session must not be interrupted).
    var isSessionActive: Bool { sessionGranted }
    /// The phone the user last connected to — preferred on reconnect.
    private var lastAttemptedPhoneName: String?
    /// Bidirectional pairing: first contact is explicit (the user picks
    /// a phone in the menu bar, then approves on the iPhone). After a
    /// user-initiated disconnect we stay idle until the user connects
    /// again — auto-connect only ever targets paired phones, and this
    /// flag suspends even that.
    private var autoConnectSuppressed = false
    /// Set when the iPhone is busy/denied so the 3 s reconnect loop
    /// doesn't hammer it — replaced by a single slow retry + manual.
    private var suppressReconnect = false
    private var slowRetryTask: Task<Void, Never>?
    /// True while we are quietly re-trying our turn after being told the
    /// iPhone is in use. The visible state is frozen for the duration so the
    /// popover holds a single, useful line — "in use by <X>, switch on the
    /// iPhone" — instead of flickering to a bare "connecting…" every 15 s.
    private var waitingInBackground = false
    /// Abandons a direct-IP dial that hasn't reached `.ready` in 8 s —
    /// a stale address otherwise sits in `preparing` for the full ~75 s
    /// TCP timeout and blocks the healthy Bonjour path.
    private var dialWatchdogTask: Task<Void, Never>?
    /// Which attempt has already spent its one WiFi-only retry. See
    /// `PeerToPeerRetryLatch` — it was a bare `String?` whose comment promised a
    /// reset that no code performed, which made the retry once-per-process.
    private var peerToPeerRetryLatch = PeerToPeerRetryLatch()
    /// One notification per run, and one per *wait* — see
    /// `ApprovalNotificationPolicy` for why the transition and not the state.
    private var didNotifyAboutApprovalThisRun = false
    private var notifiedAboutCurrentWait = false
    /// Abandons a connection that reaches TCP `.ready` but never gets a
    /// `sessionReply` (the phone backgrounded mid-handshake). Without
    /// this the Mac stays in `.handshaking` with `connection != nil`
    /// forever and refuses to dial again — the "can't connect" deadlock.
    private var handshakeTimeoutTask: Task<Void, Never>?
    /// Bonjour-empty fallback loop: direct-dials candidate IPs when
    /// multicast discovery yields nothing (Personal Hotspot, client
    /// isolation, some VPNs all break mDNS while plain TCP still works).
    private var fallbackTask: Task<Void, Never>?
    /// True when the live connection was dialed by IP (fallback/manual)
    /// rather than via a Bonjour service endpoint — such connections
    /// learn the phone's real service name only from its metadata.
    private var connectedIsDirect = false
    /// The IPv4 we dialed on a direct connection (for the name map).
    private var connectedDirectIP: String?

    private struct IncomingFile {
        let id: String
        let url: URL
        let handle: FileHandle
        var received: Int64
        let declared: Int64
    }
    private var incoming: IncomingFile?

    /// Files awaiting a Finder reveal. A multi-file send completes each
    /// file back-to-back; revealing once per file would yank Finder to
    /// the front repeatedly, so reveals are coalesced over a short window.
    private var pendingRevealURLs: [URL] = []
    private var revealTask: Task<Void, Never>?

    init() {
        pairedPhones = tokenStore.keys.sorted()
        decoder.onDecoded = { [weak self] image in
            Task { @MainActor in
                self?.cameraSinkFeeder.feed(image: image)
                self?.latestFrame = image
                self?.recorder.appendVideo(image)
            }
        }
        cameraSinkFeeder.start()
        audioPlayer.onLevel = { [weak self] level in
            // onLevel fires on the audio player's private queue.
            Task { @MainActor in
                self?.micLevel = level
            }
        }
        audioPlayer.setMuted(monitoringMuted)
        audioPlayer.start()
        Self.log.info("accessibility trusted: \(AXIsProcessTrusted(), privacy: .public)")
        start()

        // Tell the phone this computer is online. Independent of any session.
        let advertiser = PresenceAdvertiser(id: macId, name: macName)
        advertiser.start()
        presenceAdvertiser = advertiser

        // Debug: dump the window-capture result and exit. Lets a human (or
        // a script) verify the picker's data without a paired iPhone.
        if ProcessInfo.processInfo.environment["REMOTECRAB_DEBUG_WINDOW_DUMP"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let list = await WindowCapture.buildList()
                let previews = list.windows.filter { $0.snapshotJPEG != nil }.count
                Self.log.info("WINDOW DUMP: canCapture=\(list.canCapture, privacy: .public) total=\(list.windows.count, privacy: .public) previews=\(previews, privacy: .public)")
                for window in list.windows {
                    Self.log.info("WINDOW DUMP: \(window.appName, privacy: .public) | \(window.title, privacy: .public) | \(Int(window.width), privacy: .public)x\(Int(window.height), privacy: .public) | jpeg=\(window.snapshotJPEG?.count ?? 0, privacy: .public)B")
                }
                exit(0)
            }
        }

        // Keep the iPhone's app switcher in sync with launches,
        // terminations and frontmost changes.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.publishMacApps()
                    // The picker renders `macWindows`, not `macApps` — so an
                    // app that starts (the launcher sheet, the shortcut bar,
                    // Show Desktop) has to be republished as a *window* or it
                    // cannot become a card in the sheet the user is looking
                    // at, and one that quits must disappear from it.
                    switch name {
                    case NSWorkspace.didLaunchApplicationNotification:
                        // The window arrives with the activation that follows,
                        // so wait for the pair rather than for the process.
                        self.scheduleWindowRefresh(expectsActivation: true)
                    case NSWorkspace.didTerminateApplicationNotification:
                        self.scheduleWindowRefresh(expectsActivation: false)
                    default:
                        // `didActivate` is only interesting as the second half
                        // of a launch. Alone — every app switch, every dialog,
                        // every sheet — a rebuild costs a JPEG per window and
                        // changes nothing the picker shows.
                        self.windowRefreshPushesForActivation()
                    }
                }
            }
        }
    }

    // MARK: - App switcher (Mac → iPhone)

    /// Send the current regular-app list to the iPhone. No-op unless a
    /// session owner is established. `includeIcons` is true only when the
    /// iPhone explicitly asked (switcher opened / refreshed) — icon PNGs
    /// are the expensive part of the frame, so automatic refreshes omit
    /// them and the iPhone reuses its own cache.
    func publishMacApps(includeIcons: Bool = false) {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> IBAppInfo in
                let bid = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                return IBAppInfo(id: bid,
                                 name: app.localizedName ?? bid,
                                 pid: app.processIdentifier,
                                 isActive: app.isActive,
                                 iconPNG: includeIcons ? iconPNG(for: app, key: bid) : nil)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        macApps = apps
        Self.log.info("published \(apps.count, privacy: .public) apps to iPhone (icons: \(includeIcons, privacy: .public))")
        if let data = try? IBWire.encode(appList: IBAppList(apps: apps)) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Rasterize an app icon to a 128 px PNG once and cache it by id.
    private func iconPNG(for app: NSRunningApplication, key: String) -> Data? {
        if let cached = iconCache[key] { return cached }
        guard let image = app.icon else { return nil }
        let side: CGFloat = 128
        let resized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconCache[key] = png
        return png
    }

    /// Build and send the window list for the iPhone's full-screen window
    /// picker. If Screen Recording isn't granted we ask once (System
    /// Settings) and send an app-level list so the picker still works.
    func publishMacWindows() {
        lastWindowListRequestAt = Date()
        guard sessionGranted, let connection, connection.state == .ready else { return }
        if !WindowCapture.isAuthorized, !didRequestScreenRecording {
            didRequestScreenRecording = true
            WindowCapture.requestAccess()
        }
        Task { [weak self] in
            let list = await WindowCapture.buildList()
            guard let self, self.sessionGranted,
                  let connection = self.connection, connection.state == .ready else { return }
            let previews = list.windows.filter { $0.snapshotJPEG != nil }.count
            Self.log.info("published \(list.windows.count, privacy: .public) windows (\(previews, privacy: .public) with previews, canCapture=\(list.canCapture, privacy: .public))")
            if let data = try? IBWire.encode(windowList: list) {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Refresh the window picker only if the iPhone asked for it recently
    /// (i.e. the picker is probably open). Used for background events like
    /// an app quitting or starting on its own.
    private func publishMacWindowsIfRecentlyRequested() {
        guard let at = lastWindowListRequestAt,
              Date().timeIntervalSince(at) < windowPickerFreshness else { return }
        publishMacWindows()
    }

    /// How long after the iPhone asked for the window list a workspace
    /// change still counts as "the picker may be open".
    ///
    /// Was 30 s, which is shorter than the flow it has to survive: open the
    /// picker, browse the launcher grid, pick an app. The launch then landed
    /// outside the window and the app the user just opened still didn't
    /// appear. Long enough to cover a deliberate browse, still bounded so
    /// a closed picker costs nothing.
    private let windowPickerFreshness: TimeInterval = 120

    /// Queue a window-list rebuild once the current burst of workspace
    /// notifications goes quiet. `expectsActivation` marks it as a launch,
    /// which the matching `didActivate` is allowed to push back — see
    /// `windowRefreshPushesForActivation`.
    private func scheduleWindowRefresh(expectsActivation: Bool) {
        guard sessionGranted else { return }
        windowChangeExpectsActivation = expectsActivation
        windowChangeCoalescer.signal(now: Date())
        guard windowChangeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireWindowRefreshIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowChangeTimer = timer
    }

    /// The activation half of a launch. It only means something while a
    /// launch is pending; every other activation is a window the picker
    /// already shows.
    private func windowRefreshPushesForActivation() {
        guard windowChangeCoalescer.isPending, windowChangeExpectsActivation else { return }
        windowChangeCoalescer.signal(now: Date())
    }

    private func fireWindowRefreshIfDue() {
        // A session that ended mid-wait leaves nothing to refresh. Drop the
        // timer with it instead of idling at 5 Hz for the rest of the run.
        guard sessionGranted else {
            stopWindowRefresh()
            return
        }
        guard windowChangeCoalescer.isDue(now: Date()) else { return }
        stopWindowRefresh()
        publishMacWindowsIfRecentlyRequested()
    }

    private func stopWindowRefresh() {
        windowChangeCoalescer.cancel()
        windowChangeExpectsActivation = false
        windowChangeTimer?.invalidate()
        windowChangeTimer = nil
    }

    /// Send every launch-able application for the iPhone's launcher sheet
    /// (kind 0x21). Enumerated on the fly — the set changes when apps are
    /// installed/uninstalled, so caching buys nothing.
    func publishInstalledApps() {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        Task { [weak self] in
            let started = Date()
            let apps = await InstalledAppsCatalog.all()
            guard let self, self.sessionGranted,
                  let connection = self.connection, connection.state == .ready else { return }
            Self.log.info("published \(apps.count, privacy: .public) installed apps")
            guard let data = try? IBWire.encode(installedApps: IBInstalledApps(apps: apps)) else { return }
            // The frame size is the whole point of the JPEG switch, so it is
            // logged next to the count: 113 apps was 14.25 MB as 192px
            // lossless PNG and is 1.06 MB as 192px JPEG.
            Self.log.info("installedApps frame: \(data.count / 1024, privacy: .public)KB in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - App screen mirror (Mac → iPhone)

    /// Handle `screenControl` (0x1D): start / stop / select / follow / extend.
    private func handleScreenControl(_ control: IBScreenControl) {
        switch control.command {
        case .start:
            // A new session invalidates the injector's "the cursor is
            // already inside the window" memory: the user may have moved
            // their own mouse to another app since the last session, so the
            // first scroll would land over there.
            inputInjector.resetMirrorCursor()
            ensureScreenStreamer()
            screenStreamer?.setMaxPixel(control.maxPixel)
            screenStreamer?.start()
        case .stop:
            teardownVirtualDisplay()
            screenStreamer?.stop()
            screenStreamer = nil
            lastScreenInfo = nil
            Self.log.info("screen mirror stopped")
        case .select:
            teardownVirtualDisplay()
            screenStreamer?.select(windowId: control.windowId ?? "")
        case .follow:
            teardownVirtualDisplay()
            screenStreamer?.follow()
        case .extend:
            // The phone wants a real second monitor: create a virtual
            // display, then point the live mirror at it. All the plumbing
            // (capture/encode/decode/render/input) is the existing mirror.
            // `ensureScreenStreamer` so an extend that arrives without a
            // preceding `.start` (or after a `.stop`) still works instead
            // of silently doing nothing.
            ensureScreenStreamer()
            screenStreamer?.setMaxPixel(control.maxPixel)
            let width = control.maxPixel ?? 1920
            Task { @MainActor [weak self] in
                guard let self else { return }
                let vd = self.virtualDisplay ?? VirtualDisplay()
                self.virtualDisplay = vd
                guard let id = await vd.create(width: width, height: width * 10 / 16) else {
                    Self.log.error("extend failed — no virtual display")
                    return
                }
                self.screenStreamer?.extend(displayID: id)
            }
        }
    }

    /// Create the mirror streamer on demand. `.start` and `.extend` both
    /// need it — an extend that arrives without a preceding start must not
    /// silently no-op.
    private func ensureScreenStreamer() {
        guard screenStreamer == nil else { return }
        // Capture the live connection so the streamer never has to know
        // about `ReceiverSession`; frames go out on the same socket as
        // every other event.
        let conn = connection
        let streamer = ScreenStreamer { data in
            conn?.send(content: data, completion: .contentProcessed { _ in })
        }
        streamer.onInfo = { [weak self] info in
            Task { @MainActor in self?.lastScreenInfo = info }
        }
        screenStreamer = streamer
        Self.log.info("screen mirror created")
    }

    /// Drop the extended virtual display, if one is up.
    private func teardownVirtualDisplay() {
        guard let vd = virtualDisplay else { return }
        vd.destroy()
        virtualDisplay = nil
    }

    /// Handle `screenInput` (0x1E): absolute clicks / drags / scroll inside
    /// the mirrored window, translated through the last known geometry.
    private func handleScreenInput(_ input: IBScreenInput) {
        guard let info = lastScreenInfo, info.status == .ok else { return }
        let origin = CGPoint(x: info.originX, y: info.originY)
        let size = CGSize(width: info.width, height: info.height)
        // Protocol method (default no-op) so a test injector can record
        // screen input without a macOS-specific cast.
        inputInjector.inject(screenInput: input, windowOrigin: origin, windowSize: size)
    }

    /// Resolve an app by bundle id, or `pid:<n>` when it has no bundle id.
    private func resolveApp(id: String) -> NSRunningApplication? {
        if id.hasPrefix("pid:"), let pid = Int32(id.dropFirst(4)) {
            return NSRunningApplication(processIdentifier: pid_t(pid))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    private func activateApp(id: String, windowTitle: String?) -> IBCommandResult.Status {
        guard let app = resolveApp(id: id) else {
            Self.log.info("activateApp: not running (\(id, privacy: .public))")
            return .appNotRunning
        }
        let pid = app.processIdentifier
        // `activate` returns a Bool that is routinely false — a missing
        // Accessibility grant looks exactly like success otherwise, and
        // the phone is left staring at a screen that did not change.
        //
        // `.activateAllWindows` looks wrong for an *app* tap (it un-piles
        // every window the app owns), but it is what makes a tapped *window
        // card* work at all — see d49e3f7, 2026-09-20. Do not remove it on
        // the strength of a symptom that has not been reproduced: a report
        // of "opening an app also opens its windows" turned out to come from
        // the **launcher** sheet, not from this path, and it stopped
        // reproducing before it could be traced.
        let raised = app.activate(options: [.activateAllWindows])
        if let windowTitle, !windowTitle.isEmpty {
            return raiseWindow(pid: pid, title: windowTitle) ? .ok : .noWindow
        }
        Self.log.info("activated app \(app.localizedName ?? id, privacy: .public) window=\(windowTitle ?? "-", privacy: .public) raised=\(raised, privacy: .public)")
        return raised ? .ok : .noPermission
    }

    /// Answer a request that carried a `requestId`.
    ///
    /// A `nil` id means the phone predates `commandResult`: honour the
    /// command, say nothing. Silence is the correct reply to a peer that
    /// cannot read the answer, and the phone interprets it as "your Mac app
    /// is too old to confirm" rather than as a failure.
    private func reply(_ requestId: String?, _ status: IBCommandResult.Status) {
        guard let requestId, let broadcaster else { return }
        broadcaster.send(IBCommandResult(requestId: requestId, status: status))
    }

    private func activateAppAndRepublish(id: String, windowTitle: String?) -> IBCommandResult.Status {
        let status = activateApp(id: id, windowTitle: windowTitle)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.publishMacApps()
        }
        return status
    }

    /// Bring one window of `pid` to the front — un-minimizing it first —
    /// via Accessibility, matched by title. Plain app activation can't
    /// surface a specific (possibly minimized/behind) window, which read
    /// as "the picker can't switch me there".
    /// Returns whether the window was found and raised.
    private func raiseWindow(pid: pid_t, title: String) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            Self.log.info("raiseWindow: no AX windows for pid \(pid, privacy: .public)")
            return false
        }
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard ((titleRef as? String) ?? "") == title else { continue }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            Self.log.info("raised window \(title, privacy: .public)")
            return true
        }
        Self.log.info("raiseWindow: no AX title match for \(title, privacy: .public)")
        return false
    }

    /// Quit the identified app. Graceful by default — the app may raise a
    /// save sheet on the Mac (invisible from the iPhone) — or immediate
    /// when `force` is set, which can lose unsaved work.
    private func quitApp(id: String, force: Bool) -> IBCommandResult.Status {
        guard let app = resolveApp(id: id) else {
            Self.log.info("quitApp: not running (\(id, privacy: .public))")
            return .appNotRunning
        }
        // `terminate`/`forceTerminate` answer whether the request was
        // ACCEPTED, not whether the app has exited — a graceful quit blocked
        // by an invisible save sheet is accepted, then silently reappears.
        // Still worth reporting: "we asked" is true, "it happened" is not.
        let requested = force ? app.forceTerminate() : app.terminate()
        Self.log.info("quitApp \(app.localizedName ?? id, privacy: .public) force=\(force, privacy: .public) accepted=\(requested, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.publishMacApps()
            // The user quit from the picker — republish the window list so
            // the card disappears from the still-open sheet.
            self?.publishMacWindows()
        }
        return requested ? .ok : .failed
    }

    // MARK: - Recording

    /// Toggle recording of the live video + audio to `~/Movies/RemoteCrab`.
    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start()
        }
        isRecording = recorder.isRecording
        Self.log.info("recording toggled: \(self.isRecording, privacy: .public)")
    }

    // MARK: - File receive (iPhone → Mac)

    private static func incomingDirectory() -> URL {
        MacPaths.directory("Downloads/RemoteCrab")
    }

    /// Strip any path components so a malicious name can't escape the
    /// destination folder.
    private static func sanitizedFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func beginIncoming(_ offer: IBFileOffer) {
        finishIncoming() // close any half-open transfer
        let url = Self.uniqueURL(Self.incomingDirectory()
            .appendingPathComponent(Self.sanitizedFileName(offer.name)))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("cannot open \(url.path, privacy: .public) for writing")
            sendFileAck(IBFileAck(id: offer.id, status: .error, receivedBytes: 0))
            return
        }
        incoming = IncomingFile(id: offer.id, url: url, handle: handle, received: 0, declared: offer.size)
        Self.log.info("receiving file \(offer.name, privacy: .public) (\(offer.size) bytes)")
        sendFileAck(IBFileAck(id: offer.id, status: .progress, receivedBytes: 0))
    }

    private func appendIncoming(_ data: Data) {
        guard var file = incoming else { return }
        do {
            try file.handle.write(contentsOf: data)
        } catch {
            Self.log.error("file write failed: \(error, privacy: .public)")
            sendFileAck(IBFileAck(id: file.id, status: .error, receivedBytes: file.received))
            return
        }
        file.received += Int64(data.count)
        incoming = file
        // Throttle progress acks to roughly every 2 MiB.
        if file.received / (2 * 1024 * 1024) != (file.received - Int64(data.count)) / (2 * 1024 * 1024) {
            sendFileAck(IBFileAck(id: file.id, status: .progress, receivedBytes: file.received))
        }
    }

    private func finishIncoming() {
        guard let file = incoming else { return }
        try? file.handle.close()
        incoming = nil
        lastReceivedFileURL = file.url
        Self.log.info("file saved \(file.url.path, privacy: .public) (\(file.received) bytes)")
        sendFileAck(IBFileAck(id: file.id, status: .saved,
                              receivedBytes: file.received, path: file.url.path))
        // AirDrop-like landing: open the folder with the file selected.
        // Coalesced so a multi-file send reveals them together once.
        scheduleReveal(file.url)
    }

    /// Reveal `url` in Finder, batched with any other files that land
    /// within the next moment.
    private func scheduleReveal(_ url: URL) {
        pendingRevealURLs.append(url)
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.pendingRevealURLs.isEmpty else { return }
            let urls = self.pendingRevealURLs
            self.pendingRevealURLs = []
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func sendFileAck(_ ack: IBFileAck) {
        guard let connection, connection.state == .ready,
              let data = try? IBWire.encode(fileAck: ack) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Selection rewrite

    /// Transform the Mac's current selection in place (local, offline).
    ///
    /// Uses synthetic ⌘C / ⌘V rather than the Accessibility API: a
    /// sandboxed app can post key events but cannot read another app's
    /// AX tree, so AX `kAXSelectedTextAttribute` silently returns
    /// nothing. The clipboard is saved and restored around the edit.
    private func applyTextCommand(_ command: IBTextCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let selected = await self.copyFrontmostSelection(), !selected.isEmpty else {
                Self.log.info("text command \(command.rawValue, privacy: .public): no selection")
                return
            }
            let transformed = TextTransform.apply(command, to: selected)
            self.pasteToFrontmost(transformed)
            Self.log.info("text command \(command.rawValue, privacy: .public): \(selected.count) → \(transformed.count) chars")
        }
    }

    private func copyFrontmostSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        postCommandKey(keycode: 8) // ⌘C
        try? await Task.sleep(for: .milliseconds(200))
        let copied = pasteboard.string(forType: .string)
        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        return (copied?.isEmpty == false) ? copied : nil
    }

    private func pasteToFrontmost(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCommandKey(keycode: 9) // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let saved else { return }
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    private func postCommandKey(keycode: UInt16) {
        inputInjector.inject(key: KeyEvent(action: .down, keycode: keycode, modifiers: 8))
        inputInjector.inject(key: KeyEvent(action: .up, keycode: keycode, modifiers: 8))
    }

    // MARK: - Clipboard

    /// Push the Mac's clipboard text to the iPhone.
    func sendClipboardToPhone() {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty,
              let data = try? IBWire.encode(clipboard: IBClipboard(text: text)) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
        Self.log.info("clipboard sent to iPhone (\(text.count) chars)")
    }

    // MARK: - Notification relay (Mac → iPhone)

    /// Start polling the Mac's Notification Center and relaying
    /// non-denylisted banners. No-op unless `remotecrab.mac.notifyRelay`
    /// is on (default off — privacy first). Best-effort: a missing
    /// Accessibility grant or a changed AX tree just yields nothing.
    private func startNotificationRelay() {
        stopNotificationRelay()
        // E2E may force it on for one run so the suite can cover the relay
        // without touching the user's saved preference (mirrors AUTOPAIR).
        let forced = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_NOTIFY_RELAY"] == "1"
        guard forced || UserDefaults.standard.bool(forKey: "remotecrab.mac.notifyRelay") else { return }
        let denylist = UserDefaults.standard.stringArray(forKey: "remotecrab.mac.notifyDenylist")
            ?? NotificationFilter.defaultDenylist
        let capture = NotificationCapture(denylist: denylist)
        capture.onBanner = { [weak self] notification in
            self?.sendNotification(notification)
        }
        capture.start()
        notificationCapture = capture
        Self.log.info("notification relay started (denylist \(denylist.count, privacy: .public) apps)")
    }

    private func stopNotificationRelay() {
        notificationCapture?.stop()
        notificationCapture = nil
    }

    /// Preferences toggle: apply immediately while a session is live.
    /// (When disconnected the setting is simply read on the next accept.)
    func setNotificationRelay(_ enabled: Bool) {
        guard sessionGranted else { return }
        if enabled { startNotificationRelay() } else { stopNotificationRelay() }
    }

    /// Mac → iPhone: relay one captured notification banner. Silently
    /// dropped when the session isn't live (v1 does not queue offline).
    func sendNotification(_ notification: IBNotification) {
        guard sessionGranted, let broadcaster else { return }
        // Attach the notifying app's current front window so tapping the
        // banner on the iPhone lands in that window (the Mac side's
        // `activateApp` raises it by title). Nil when Screen Recording is not
        // granted — window *names* are redacted without it — in which case a
        // tap still just activates the app.
        let withWindow = IBNotification(app: notification.app,
                                        title: notification.title,
                                        subtitle: notification.subtitle,
                                        body: notification.body,
                                        windowTitle: frontWindowTitle(ownerName: notification.app))
        broadcaster.send(withWindow)
    }

    /// Title of `ownerName`'s frontmost normal window, or nil.
    ///
    /// One `CGWindowListCopyWindowInfo` call; the list is front-to-back, so
    /// the selection logic lives in the pure, tested `NotificationWindowMatch`.
    private func frontWindowTitle(ownerName: String) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let windows = list.compactMap { info -> NotificationWindowInfo? in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return NotificationWindowInfo(ownerName: owner, pid: pid, layer: layer,
                                          title: info[kCGWindowName as String] as? String)
        }
        return NotificationWindowMatch.frontWindowTitle(ownerName: ownerName, in: windows)
    }

    // MARK: - Identity

    private static func loadMacId() -> String {
        let key = "remotecrab.mac.id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func loadMacName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func loadTokens() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "remotecrab.mac.tokens"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveTokens() {
        guard let data = try? JSONEncoder().encode(tokenStore) else { return }
        UserDefaults.standard.set(data, forKey: "remotecrab.mac.tokens")
        pairedPhones = tokenStore.keys.sorted()
    }

    // MARK: - Discovery

    func start() {
        browser.start(serviceType: IBServiceType.tcp) { [weak self] phones in
            Task { @MainActor in
                self?.handleDiscovered(phones)
            }
        }
        startFallbackLoop()
    }

    /// Mac → iPhone: toggle a feature remotely. No-op when disconnected.
    func setFeature(_ feature: IBFeature, _ enabled: Bool) {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        do {
            let data = try IBWire.encode(featureControl: FeatureControl(feature: feature, enabled: enabled))
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("featureControl encode failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Speaker path (the Mac captures, the phone plays)

    /// Start capturing the Mac's audio and pumping it to the phone.
    /// Idempotent, because the request can arrive from the phone's toggle,
    /// from the Mac's own menu row, and from a `featureState` replay after
    /// a reconnect — and each of those can fire twice.
    /// Whether the Mac's own speakers go quiet while the phone plays.
    ///
    /// Defaults to YES (AirPlay semantics), and it is a real preference rather
    /// than a constant because the right answer depends on the machine: on a
    /// Mac mini or a desktop with no speakers there is nothing to silence,
    /// and a user who wants to hear both has no reason to be argued with.
    /// Read with `object(forKey:)` rather than `bool(forKey:)` so "never set"
    /// can mean true instead of silently meaning false.
    static let speakerMutesLocalKey = "remotecrab.mac.speakerMutesLocal"

    var speakerMutesLocal: Bool {
        UserDefaults.standard.object(forKey: Self.speakerMutesLocalKey) as? Bool ?? true
    }

    func startSpeakerCapture(mute: SystemAudioTapMute? = nil) {
        let mute = mute ?? (speakerMutesLocal ? SystemAudioTapMute.muteWhileTapped
                                              : SystemAudioTapMute.keepLocalAudio)
        guard sessionGranted, let connection, connection.state == .ready else {
            speakerStatus = String(IBLocale.Speaker.notConnectedNoAudio)
            return
        }
        if speakerTap.running { return }

        do {
            try speakerTap.start(mute: mute)
        } catch {
            // Surface the reason AND the action. A switch that silently does
            // nothing is the failure mode rule 1 exists to prevent.
            speakerStatus = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Self.log.error("speaker tap failed: \(String(describing: error), privacy: .public)")
            return
        }

        speakerStatus = nil
        lastLevelReportAt = -1
        Self.log.info("speaker capture started (mute=\(mute.rawValue, privacy: .public))")

        speakerPumpTask?.cancel()
        speakerPumpTask = Task { [weak self] in
            // 10 ms keeps the 500 ms ring comfortably drained without
            // waking the CPU 100 times a second for nothing: the tap hands
            // over 512 frames (10.67 ms) per callback, so this is one poll
            // per incoming buffer.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                self?.pumpSpeakerAudio()
            }
        }
    }

    func stopSpeakerCapture() {
        speakerPumpTask?.cancel()
        speakerPumpTask = nil
        guard speakerTap.running else { speakerStatus = nil; return }
        speakerTap.stop()
        speakerStatus = nil
        Self.log.info("speaker capture stopped (captured \(self.speakerTap.capturedFrameCount, privacy: .public) frames)")
    }

    /// Drain whatever the tap has buffered and ship it. Sends nothing while
    /// disconnected, and never blocks the realtime side.
    private func pumpSpeakerAudio() {
        guard speakerTap.running,
              sessionGranted, let connection, connection.state == .ready else { return }
        var sent = 0
        var packetRms = 0.0
        var packetPeak = 0
        let tap = speakerTap
        while let pcm = tap.takePacket() {
            // Measure the PACKET, not the tap. The tap can be loud while the
            // packet is silent, and those are two completely different bugs.
            pcm.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                var sum = 0.0
                for v in s { sum += Double(v) * Double(v) }
                packetRms = s.isEmpty ? 0 : (sum / Double(s.count)).squareRoot()
                for v in s { packetPeak = max(packetPeak, abs(Int(v))) }
            }
            let packet = AudioPacket(
                opusData: pcm,
                sampleRate: Int(SystemAudioTap.sampleRate),
                channels: SystemAudioTap.channels,
                timestampMicros: UInt64(Date().timeIntervalSince1970 * 1_000_000),
                codec: AudioPacket.codecPCM)
            guard let data = try? IBWire.encode(speakerAudio: packet) else { break }
            connection.send(content: data, completion: .contentProcessed { _ in })
            sent += 1
            packetBytes = pcm.count
            if sent >= 20 { break }   // never let a backlog starve the rest of the link
        }
        if sent > 0 {
            let bytesOut = packetBytes
            Self.log.info("speaker packet: bytes=\(bytesOut) rms=\(Int(packetRms)) peak=\(packetPeak) sent=\(sent) ringNewest=\(tap.newestRingSample) avail=\(tap.lastAvailableFrames) dropped=\(tap.droppedFrameCount)")
            speakerCapturedFrames = speakerTap.capturedFrameCount
            speakerDroppedFrames = speakerTap.droppedFrameCount
            // Once a second, and ONLY the level: this is the line that
            // separates "the tap is dead" from "the Mac is not making any
            // sound", which the packet counts cannot.
            let seconds = Double(tap.capturedFrameCount) / 48_000
            if sent == 1 || seconds - lastLevelReportAt > 1.0 {
                lastLevelReportAt = seconds
                Self.log.info("speaker tap level: rms=\(Int(tap.capturedRms)) peak=\(tap.capturedPeak) frames=\(tap.capturedFrameCount)")
            }
        }
    }

    /// Mac → iPhone: switch the streaming camera. No-op when disconnected.
    func switchCamera(to position: IBCameraPosition) {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        do {
            let data = try IBWire.encode(cameraCommand: IBCameraCommand(position: position))
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("cameraCommand encode failed: \(error, privacy: .public)")
        }
    }

    /// Flip the iPhone's camera between front and back.
    func toggleCamera() {
        switchCamera(to: (featureState?.cameraPosition ?? .back).toggled)
    }

    private func handleDiscovered(_ phones: [DiscoveredPhone]) {
        discovered = phones
        Self.log.info("discovered \(phones.count, privacy: .public) phone(s); connection==nil: \(self.connection == nil, privacy: .public)")
        let autoConnectEnabled = UserDefaults.standard.object(forKey: "remotecrab.autoReconnect") as? Bool ?? true
        guard !autoConnectSuppressed, autoConnectEnabled else { return }
        // Bidirectional pairing: the Mac never connects to an iPhone it
        // hasn't paired with — the user picks one from the Devices list
        // and the iPhone shows its approval card. A phone this Mac holds
        // a token for was approved on both sides already, so it may
        // connect on sight (this is also the reconnect-after-drop path).
        // Prefer a phone this Mac already paired with. If none is around,
        // dial the first discovered phone anyway: the iPhone decides
        // (accepted / pending / busy) and shows its approval card, instead
        // of leaving the user stuck on "waiting" because a reinstall or a
        // settings migration dropped the local token.
        guard let phone = phones.first(where: { tokenStore[$0.name] != nil }) ?? phones.first else { return }
        if connection == nil {
            connect(to: phone)
        } else if case .connecting = state {
            // A paired phone just appeared on Bonjour while a SPECULATIVE
            // dial (e.g. a stale last-known-IP direct link) is still in
            // `preparing` — a dead route can sit there for ~75 s of TCP
            // timeout and would otherwise block the healthy path forever.
            // The discovered phone is real; the in-flight attempt is only
            // a guess, so the guess loses.
            Self.log.info("paired phone discovered while an unready dial is in flight — switching to Bonjour")
            connect(to: phone)
        }
    }

    /// UI action: the user picked a discovered iPhone — explicit consent
    /// on the Mac side, matching the iPhone's approval card.
    func connectTo(_ phone: DiscoveredPhone) {
        autoConnectSuppressed = false
        connect(to: phone)
    }

    /// UI action: hang up and stay idle until the user connects again.
    func disconnect() {
        autoConnectSuppressed = true
        suppressReconnect = true
        slowRetryTask?.cancel()
        slowRetryTask = nil
        connection?.cancel()
        // The .cancelled state callback keeps the current state when
        // suppressReconnect is set, so land on .searching ourselves.
        state = .searching
        Self.log.info("user disconnected")
    }

    /// Preferences → Paired iPhones: drop the stored token so the next
    /// contact with that phone requires approval again (both sides have
    /// symmetric Forget actions).
    func forgetPhone(named name: String) {
        tokenStore.removeValue(forKey: name)
        saveTokens()
        Self.log.info("forgot paired phone \(name, privacy: .public)")
    }

    /// Whether this Mac holds a pairing token for a discovered phone.
    func isPaired(_ phone: DiscoveredPhone) -> Bool {
        tokenStore[phone.name] != nil
    }

    /// Manual "connect by IP" fallback for networks where Bonjour is
    /// blocked. `host` may be an IP or hostname; `port` defaults to the
    /// iPhone's fixed port.
    func connectManually(host: String, port: UInt16) {
        let phone = DiscoveredPhone(id: "manual:\(host):\(port)",
                                    name: "\(host):\(port)",
                                    endpoint: host, port: port,
                                    serviceEndpoint: nil)
        autoConnectSuppressed = false
        connect(to: phone)
    }

    // MARK: - Direct-connect fallback (Bonjour blocked)

    /// While Bonjour reports an empty network, periodically probe
    /// candidate IPs with a short-timeout TCP dial and connect to the
    /// first one that answers. Only runs in the idle `.searching` state
    /// — never over a live connection, after a manual disconnect, or
    /// while a busy/denied backoff is in effect.
    private func startFallbackLoop() {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            // Bonjour answers in under a second on healthy networks;
            // give it a head start before dialing blindly.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                guard UserDefaults.standard.object(forKey: "remotecrab.autoReconnect") as? Bool ?? true else { return }
                if self.connection == nil,
                   !self.autoConnectSuppressed, !self.suppressReconnect,
                   case .searching = self.state,
                   // "Empty" for fallback purposes means: nothing we
                   // could auto-connect to. A stale or unpaired Bonjour
                   // record must not suppress the direct-IP probe —
                   // that was the "iPhone stuck on 连接中" deadlock.
                   !self.discovered.contains(where: { self.tokenStore[$0.name] != nil }) {
                    await self.probeFallbackCandidates()
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// IPs worth a direct dial, most specific first: the phone we last
    /// connected to, then the Personal Hotspot gateway when this Mac is
    /// on the iPhone's hotspot (172.20.10.0/28 — mDNS does not reach
    /// hotspot clients, but the phone itself is always the gateway).
    private func fallbackCandidates() -> [String] {
        var out: [String] = []
        // Only a plausible LAN address is a candidate. A persisted loopback
        // or link-local address is not the phone, and dialling it attaches to
        // whatever else answers (a simulator, in practice).
        if let last = UserDefaults.standard.string(forKey: "remotecrab.lastPhoneIP"),
           DirectDialAddress.isUsable(last) {
            out.append(last)
        }
        if Self.localIPv4InHotspotSubnet() {
            out.append("172.20.10.1")
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func probeFallbackCandidates() async {
        let port: UInt16 = 8765
        for host in fallbackCandidates() {
            if Task.isCancelled || connection != nil { return }
            guard await Self.probeReachable(host: host, port: port) else { continue }
            let name = Self.phoneNameByIP[host] ?? IBLocale.Connection.directPhone
            Self.log.info("Bonjour empty; direct-connecting to \(host, privacy: .public)")
            connect(to: DiscoveredPhone(id: "direct:\(host):\(port)",
                                        name: name,
                                        endpoint: host, port: port,
                                        serviceEndpoint: nil))
            return
        }
    }

    /// Short-timeout TCP dial used by the fallback — 2.5 s instead of
    /// the system default (~75 s) so a stale last-known IP costs one
    /// probe cycle, not a minute of "connecting".
    private static func probeReachable(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { cont in
            final class Box: @unchecked Sendable { var resumed = false }
            let box = Box()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: Self.tcpParameters())
            let finish: @Sendable (Bool) -> Void = { ok in
                guard !box.resumed else { return }
                box.resumed = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            Task {
                try? await Task.sleep(for: .milliseconds(2500))
                finish(false)
            }
        }
    }

    /// TCP parameters for dialing the iPhone, with AWDL (peer-to-peer
    /// Wi-Fi) enabled unless the user turned it off in Preferences.
    /// `peerToPeer` overrides the stored preference **for this one dial only**.
    ///
    /// AWDL is how the phone stays reachable with no router at all, so it stays
    /// enabled — the dial watchdog simply asks the same resolver for a WiFi-only
    /// answer once, when the peer-to-peer endpoint did not route in the budget
    /// and there is no remembered address to fall back to. Nothing here writes
    /// the preference, so the next ordinary dial is peer-to-peer again.
    private static func tcpParameters(peerToPeer: Bool? = nil) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = peerToPeer
            ?? (UserDefaults.standard.object(forKey: "remotecrab.mac.peerToPeer") as? Bool ?? true)
        return parameters
    }

    /// True when any local interface holds an iPhone Personal Hotspot
    /// address (172.20.10.0/28 is Apple's fixed hotspot subnet).
    private static func localIPv4InHotspotSubnet() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var found = false
        for iface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = iface.pointee.ifa_addr
            guard let addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if ip.hasPrefix("172.20.10.") && ip != "172.20.10.1" { found = true }
            }
        }
        return found
    }

    /// IP → last known display name, so a direct link can show the
    /// phone's real name (and reuse its pairing token key).
    private static var phoneNameByIP: [String: String] {
        UserDefaults.standard.dictionary(forKey: "remotecrab.phoneNameByIP") as? [String: String] ?? [:]
    }

    /// Remember the phone's resolved IPv4 + name on every successful
    /// TCP connect, Bonjour or direct — Bonjour connections are how the
    /// IP is learned in the first place.
    private func persistLastPhoneEndpoint(_ conn: NWConnection) {
        guard let remote = conn.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = remote,
              case .ipv4(let addr) = host else { return }
        let ip = "\(addr)"
        // Never remember an address that cannot be a phone on the LAN —
        // persisting one makes the fallback dial a phantom and re-persist it
        // on every "successful" connect (see DirectDialAddress).
        guard DirectDialAddress.isUsable(ip) else {
            Self.log.info("not persisting unusable phone address \(ip, privacy: .public)")
            return
        }
        UserDefaults.standard.set(ip, forKey: "remotecrab.lastPhoneIP")
        if let name = connectedPhoneName {
            var map = Self.phoneNameByIP
            map[ip] = name
            UserDefaults.standard.set(map, forKey: "remotecrab.phoneNameByIP")
        }
    }

    /// - Parameter peerToPeer: overrides the AWDL preference for this dial only.
    ///   `nil` means "use the preference". See `tcpParameters(peerToPeer:)`.
    private func connect(to phone: DiscoveredPhone, peerToPeer: Bool? = nil) {
        connection?.cancel()
        connection = nil
        // Tear down the old capture now: nil-ing the connection makes the
        // old connection's `.cancelled` handler early-return, so relying
        // on it alone could leave a relay timer polling while disconnected.
        stopNotificationRelay()
        sessionGranted = false
        suppressReconnect = false
        slowRetryTask?.cancel()
        slowRetryTask = nil
        currentTokenKey = phone.name
        lastAttemptedPhoneName = phone.name
        connectedIsDirect = phone.serviceEndpoint == nil
        connectedDirectIP = phone.serviceEndpoint == nil ? phone.endpoint : nil

        if !waitingInBackground {
            state = .connecting(name: phone.name)
        }
        Self.log.info("connecting to \(phone.name, privacy: .public) (serviceEndpoint: \(phone.serviceEndpoint != nil, privacy: .public))")

        let conn: NWConnection
        // A normal dial clears the latch so THIS attempt earns its own retry;
        // the WiFi-only retry records itself so it cannot repeat. Both halves
        // are needed — clearing alone loops, recording alone works once ever.
        if peerToPeer == false {
            peerToPeerRetryLatch.retryingWithoutPeerToPeer(phone.id)
        } else {
            peerToPeerRetryLatch.diallingNormally(phone.id)
        }
        if let serviceEndpoint = phone.serviceEndpoint {
            conn = NWConnection(to: serviceEndpoint, using: Self.tcpParameters(peerToPeer: peerToPeer))
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(phone.endpoint),
                port: NWEndpoint.Port(rawValue: phone.port) ?? .any,
                using: Self.tcpParameters(peerToPeer: peerToPeer)
            )
        }
        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.handleConnectionState(newState)
            }
        }
        startReceiving(on: conn)
        conn.start(queue: .global())
        connection = conn
        connectedPhoneName = phone.name

        // A dial that has not become ready can sit in `preparing` for the full
        // TCP timeout (~75 s), and that is true of a Bonjour *service endpoint*
        // just as much as of a stale address — an endpoint resolved to an AWDL
        // interface never routes. This watchdog used to be armed ONLY for direct
        // dials, so the common case had no watchdog at all and the receiver
        // wedged until the user relaunched it. See `DialWatchdogPolicy`.
        //
        // The direct-IP fallback cannot rescue that on its own: it is gated on
        // "Bonjour empty", and Bonjour was not empty — it had found a phone
        // whose address did not work. A discovery result is not a promise that
        // the address routes.
        dialWatchdogTask?.cancel()
        let isDirectDial = phone.serviceEndpoint == nil
        dialWatchdogTask = Task { [weak self] in
            let budget = DialWatchdogPolicy.budget
            try? await Task.sleep(for: .seconds(budget))
            guard let self, !Task.isCancelled,
                  let conn = self.connection, self.connectedIsDirect == isDirectDial,
                  case .connecting = self.state else { return }
            let elapsed = budget
            guard DialWatchdogPolicy.shouldAbandon(
                isReady: false, isDirectDial: isDirectDial, elapsed: elapsed) else { return }
            let hasKnownDirectIP = !self.fallbackCandidates().isEmpty
            switch DialWatchdogPolicy.nextStep(isDirectDial: isDirectDial,
                                              hasKnownDirectIP: hasKnownDirectIP) {
            case .abandonOnly:
                Self.log.info("direct dial to \(phone.endpoint, privacy: .public) not ready after \(Int(budget))s — abandoning")
                conn.cancel()
            case .tryDirectIP:
                Self.log.info("Bonjour endpoint for \(phone.name, privacy: .public) not ready after \(Int(budget))s — abandoning it and trying the direct address")
                conn.cancel()
                if DialWatchdogPolicy.fallbackIsPossible(hasKnownDirectIP: hasKnownDirectIP) {
                    self.connection = nil
                    Task { await self.probeFallbackCandidates() }
                }
            case .retryWithoutPeerToPeer:
                guard DialWatchdogPolicy.shouldRetryWithoutPeerToPeer(
                    alreadyRetriedWithoutPeerToPeer: self.peerToPeerRetryLatch.hasRetried(phone.id)) else {
                    Self.log.info("peer-to-peer and WiFi-only dials both failed for \(phone.name, privacy: .public) — leaving it to the retry loop")
                    conn.cancel()
                    return
                }
                Self.log.info("Bonjour endpoint for \(phone.name, privacy: .public) not ready after \(Int(budget))s — retrying once without peer-to-peer (the preference is unchanged)")
                conn.cancel()
                self.connection = nil
                self.connect(to: phone, peerToPeer: false)
            }
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        Self.log.info("connection state: \(String(describing: newState), privacy: .public)")
        // Disarm the dial watchdog only when the dial it guards is no longer
        // pending. `.preparing` and `.waiting` are NOT progress — a dial can sit
        // in them for the full TCP timeout (~75 s), which is exactly what the
        // watchdog bounds — and `NWConnection` always emits `.preparing` before
        // `.ready`. This used to cancel unconditionally at the top, so the
        // watchdog was armed and disarmed within milliseconds and the common
        // Bonjour dial still wedged. See `DialWatchdogPolicy.shouldDisarmWatchdog`.
        let (isReady, isTerminal): (Bool, Bool) = {
            switch newState {
            case .ready: return (true, false)
            case .failed, .cancelled: return (false, true)
            default: return (false, false) // .preparing / .waiting / @unknown
            }
        }()
        if DialWatchdogPolicy.shouldDisarmWatchdog(ready: isReady, terminal: isTerminal) {
            dialWatchdogTask?.cancel()
            dialWatchdogTask = nil
        }
        switch newState {
        case .ready:
            // TCP is up but we are NOT the session owner yet: identify
            // ourselves and wait for the iPhone's ownership decision.
            if let connection {
                sendClientHello(on: connection)
                persistLastPhoneEndpoint(connection)
                startHandshakeTimeout(on: connection)
            }
            if let name = currentPhoneName() {
                state = .handshaking(name: name)
            }
        case .failed(let error):
            stopPingLoop()
            sessionGranted = false
            // Never surface a raw POSIX/Network error to the user —
            // log it, show a human message.
            Self.log.error("connection failed: \(error, privacy: .public)")
            if !suppressReconnect { state = .error(IBLocale.Error.iPhoneConnectionLost) }
            stopPingLoop()
            pingProbe.reset()
            latencyTracker.reset()
            clearConnectionState()
            scheduleReconnect()
        case .cancelled:
            stopPingLoop()
            pingProbe.reset()
            latencyTracker.reset()
            sessionGranted = false
            let keepError = suppressReconnect
            clearConnectionState()
            if !keepError { state = .searching }
            scheduleReconnect()
        default:
            break
        }
    }
    /// Send this Mac's identity so the iPhone can pair/authorize it.
    private func sendClientHello(on conn: NWConnection) {
        let token = currentTokenKey.flatMap { tokenStore[$0] }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2"
        // Declare what this receiver can cope with, so the phone knows when
        // to stay quiet. It MUST list `latencyProbe` here: a phone that sends
        // probes to a receiver which has not advertised the ability has its
        // timestamps subtracted from ours and paints the clock offset between
        // the two machines in the menu bar (see `pingProbe`).
        let hello = IBClientHello(name: macName, id: macId, token: token,
                                  appVersion: version,
                                  capabilities: [.latencyProbe, .commandResult])
        do {
            let data = try IBWire.encode(clientHello: hello)
            Self.log.info("clientHello sent (paired: \(token != nil, privacy: .public))")
            conn.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("clientHello encode failed: \(error, privacy: .public)")
        }
    }

    /// Give up on a `clientHello` that never gets a `sessionReply`. Only
    /// fires while still `.handshaking` — a `pending` reply (waiting for
    /// the user's approval) is a legitimate long wait and must not be cut
    /// off. Cancelling clears `connection`, so the next discovery dials.
    private func startHandshakeTimeout(on conn: NWConnection) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled,
                  self.connection === conn,
                  case .handshaking = self.state else { return }
            Self.log.info("no sessionReply after 6s — abandoning the handshake")
            conn.cancel()
        }
    }

    private func handleSessionReply(_ reply: IBSessionReply) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        Self.log.info("sessionReply: \(reply.result.rawValue, privacy: .public) owner=\(reply.ownerName ?? "-", privacy: .public)")
        // Capture the pre-reply state. The clear must run AFTER the switch
        // below has applied the new state: `clearApprovalNoticeIfResolved`
        // compares `previous` against the *current* `stateKind`, so calling it
        // here read the pre-reply state twice, the policy never saw an exit
        // from `awaitingApproval`, and a delivered "the iPhone is waiting"
        // alert stayed in Notification Center after the user had already
        // approved.
        let previous = state
        switch reply.result {
        case .accepted:
            suppressReconnect = false
            waitingInBackground = false
            slowRetryTask?.cancel()
            slowRetryTask = nil
            sessionGranted = true
            if let token = reply.token, let key = currentTokenKey {
                tokenStore[key] = token
                saveTokens()
            }
            if let name = currentPhoneName() {
                state = .streaming(name: name, latencyMs: 0)
            }
            if let connection {
                startPingLoop(on: connection)
                broadcaster = IBEventBroadcaster(connection: connection, queue: .global())
            }
            publishMacApps()
            startNotificationRelay()
            // Headless e2e: apply a text transform to whatever is
            // selected on the Mac (point TextEdit at a scratch doc and
            // select-all first).
            if let name = ProcessInfo.processInfo.environment["REMOTECRAB_E2E_TEXT_COMMAND"],
               let command = IBTextCommand(rawValue: name) {
                Task { @MainActor [weak self] in
                    // 10 s gives the tester time to focus a text field
                    // and select something after the session connects.
                    try? await Task.sleep(for: .seconds(10))
                    self?.applyTextCommand(command)
                }
            }
            // Headless e2e: record a few seconds of the live stream.
            if ProcessInfo.processInfo.environment["REMOTECRAB_E2E_RECORD"] == "1" {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.toggleRecording()
                    try? await Task.sleep(for: .seconds(6))
                    self?.toggleRecording()
                }
            }

        case .pending:
            sessionGranted = false
            if let name = currentPhoneName() {
                let beforePending = state
                state = .awaitingApproval(name: name)
                noteApprovalNeededIfFirstTime(previous: beforePending)
            }

        case .busy:
            sessionGranted = false
            suppressReconnect = true
            stopPingLoop()
            if waitingInBackground {
                // The popover is already showing the busy line with its
                // "what to do"; re-setting it every attempt would only
                // restart the same message and lose the scroll position.
                Self.log.info("still busy (owner: \(reply.ownerName ?? "?", privacy: .public)) — holding the message")
            } else {
                state = .error(reply.ownerName.map { IBLocale.Error.iphoneBusy($0) }
                               ?? IBLocale.Error.iphoneBusyUnknown)
            }
            scheduleSlowRetry()

        case .denied:
            sessionGranted = false
            suppressReconnect = true
            stopPingLoop()
            state = .error(IBLocale.Error.connectionDenied)
            // Manual retry only — don't nag a user who tapped Deny.

        case .off:
            sessionGranted = false
            suppressReconnect = true
            stopPingLoop()
            state = .error(IBLocale.Error.connectionOff)
            // Keep asking politely every 15 s: re-picking this computer on the
            // phone is the way back, and the phone has no channel to nudge us.
            // Until then every attempt is answered `off` again, so the
            // disconnect sticks.
            scheduleSlowRetry()
        }
        // Any reply other than `pending` resolves the wait — including `busy`
        // and `denied`, the phone is no longer asking for a tap. Run here, after
        // the switch, so `stateKind` is the resolved state.
        if reply.result != .pending {
            clearApprovalNoticeIfResolved(previous: previous)
        }
    }

    /// UI action: clear a busy/denied state and try again immediately.
    func retryNow() {
        suppressReconnect = false
        autoConnectSuppressed = false
        waitingInBackground = false
        slowRetryTask?.cancel()
        slowRetryTask = nil
        state = .searching
        if let phone = preferredPhone() ?? discovered.first { connect(to: phone) }
    }

    /// Keep quietly asking for our turn, indefinitely.
    ///
    /// This used to be a single 30 s retry and then it gave up, which made
    /// switching one-way: Mac → Windows worked on its own, but coming back to
    /// the Mac meant walking over to it and pressing something. The iPhone
    /// releases the session the moment the other computer disconnects (or its
    /// 10 s owner watchdog fires), so polling is what turns that into a
    /// two-way door.
    ///
    /// The loop re-arms through the refusal path: each attempt either wins the
    /// session (which cancels this task) or is refused again, which calls back
    /// into here and starts a fresh one. It also honours the user's
    /// "don't auto-reconnect" preference rather than polling against it.
    private func scheduleSlowRetry() {
        slowRetryTask?.cancel()
        slowRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                // A cancelled sleep throws, and `try?` would swallow it and
                // fall through to a spurious retryNow() — stop here instead.
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.suppressReconnect else { return }
                guard UserDefaults.standard.object(forKey: "remotecrab.autoReconnect") as? Bool ?? true
                else { return }
                self.waitingInBackground = true
                self.retryNow()
            }
        }
    }

    private func startPingLoop(on connection: NWConnection) {
        stopPingLoop()
        lastPongAt = Date()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self, weak connection] _ in
            guard let self, let connection, connection.state == .ready else { return }
            // The phone echoes every ping. Sustained silence means the
            // link is half-open (Wi-Fi dropped, phone suspended) — a
            // "ready" socket that never fires .failed. Detect it here so
            // reconnect starts in seconds, not whenever TCP notices.
            if let last = self.lastPongAt, Date().timeIntervalSince(last) > 8 {
                Self.log.error("no pong for \(Int(Date().timeIntervalSince(last)), privacy: .public)s — link is dead")
                connection.cancel()
                return
            }
            let micros = self.pingProbe.makeProbe(now: Date())
            connection.send(content: IBWire.encodePing(sentMicros: micros),
                            completion: .contentProcessed { _ in })
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingLoop() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// After a drop, retry the phone we were talking to every few
    /// seconds. The Bonjour browser keeps running, so `discovered`
    /// stays fresh; if the phone disappears the connect fails and this
    /// re-arms. Prefers a paired phone, but will re-dial any discovered
    /// phone (the iPhone gates access itself).
    private func scheduleReconnect() {
        guard !suppressReconnect else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.connection == nil else { return }
            if let phone = self.preferredPhone() {
                self.connect(to: phone)
            }
        }
    }

    /// Which discovered phone an automatic (re)connect should target:
    /// the one we were last talking to if it's still around, else any
    /// paired phone. Strangers require the explicit Devices → Connect.
    private func preferredPhone() -> DiscoveredPhone? {
        if let name = lastAttemptedPhoneName,
           let phone = discovered.first(where: { $0.name == name }) {
            return phone
        }
        return discovered.first(where: { tokenStore[$0.name] != nil }) ?? discovered.first
    }

    private func currentPhoneName() -> String? {
        connectedPhoneName
    }

    /// Wipe every piece of per-connection state when the link goes
    /// away: the feature snapshot, the test-window mirrors, and the
    /// stream state (metadata / last frame / latency) so no window
    /// keeps showing stale evidence of a dead connection.
    private func clearConnectionState() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        featureState = nil
        // The Mac must get its own sound back when the phone goes away —
        // with `muteWhileTapped` the tap keeps the hardware silent for as
        // long as it is read, so leaving it running would mute the Mac
        // against a phone that is no longer there.
        stopSpeakerCapture()
        teardownVirtualDisplay()
        screenStreamer?.stop()
        screenStreamer = nil
        lastScreenInfo = nil
        // The injector outlives the connection, so drop its mirror-cursor
        // memory too — the user's own mouse may have moved the cursor to a
        // different app while we were disconnected.
        inputInjector.resetMirrorCursor()
        stopNotificationRelay()
        broadcaster = nil
        connection = nil
        connectedPhoneName = nil
        sessionGranted = false
        try? incoming?.handle.close()
        incoming = nil
        metadata = nil
        latestFrame = nil
        latencyHistory = []
        connectedIsDirect = false
        connectedDirectIP = nil
        typedText = ""
        lastKey = nil
        touchVisual = nil
        touchTrail = []
        micLevel = 0
    }

    // MARK: - Receive loop

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.handleInbound(data)
                }
            }
            if let error {
                Self.log.error("receive failed: \(error, privacy: .public)")
                Task { @MainActor in
                    self.state = .error(IBLocale.Error.iPhoneConnectionLost)
                }
                return
            }
            if !isComplete && self.connection != nil {
                self.startReceiving(on: connection)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        let frames = parser.append(data)
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        for frame in frames {
            // The ownership decision is always processed: it is what
            // turns `sessionGranted` on.
            if frame.kind == .sessionReply {
                if let reply = try? IBWire.decodeSessionReply(frame) {
                    handleSessionReply(reply)
                }
                continue
            }
            // Nothing else is meaningful until the iPhone accepted us.
            guard sessionGranted else {
                Self.log.info("dropping \(String(describing: frame.kind), privacy: .public) before session grant")
                continue
            }
            switch frame.kind {
            case .metadata:
                handleMetadata(frame.payload)
            case .sps:
                Self.log.info("SPS received (\(frame.payload.count, privacy: .public) bytes)")
                decoder.feedSPS(frame.payload)
            case .pps:
                decoder.feedPPS(frame.payload)
            case .video:
                videoFrameCount += 1
                if videoFrameCount == 1 || videoFrameCount % 60 == 0 {
                    Self.log.info("video frames received: \(self.videoFrameCount)")
                }
                decoder.feedVideo(frame.payload)
            case .touch:
                if let event = try? IBWire.decodeTouch(frame) {
                    touchEventCount += 1
                    if touchEventCount == 1 || touchEventCount % 20 == 0 {
                        Self.log.info("touch events received: \(self.touchEventCount) (phase=\(String(describing: event.phase), privacy: .public))")
                    }
                    let vis = TouchVisual(event: event)
                    touchVisual = vis
                    touchTrail.append(vis)
                    if touchTrail.count > 120 {
                        touchTrail.removeFirst(touchTrail.count - 120)
                    }
                    inputInjector.inject(touch: event, screenSize: screenSize)
                }
            case .key:
                if let event = try? IBWire.decodeKey(frame) {
                    keyEventCount += 1
                    // Modifier keys are diagnostic gold when a held ⌥/⌘/⌃/⇧
                    // isn't reaching an input method — log every one.
                    if let code = event.keycode, (55...62).contains(code) {
                        Self.log.info("modifier key event: keycode=\(code) action=\(String(describing: event.action), privacy: .public)")
                    }
                    if let code = event.keycode, code == 51, event.action == .down {
                        Self.log.info("backspace received")
                    }
                    if keyEventCount == 1 || keyEventCount % 20 == 0 {
                        Self.log.info("key events received: \(self.keyEventCount) (action=\(String(describing: event.action), privacy: .public) text=\(event.text ?? "", privacy: .public))")
                    }
                    switch event.action {
                    case .text:
                        if let text = event.text {
                            Self.log.info("typed text: \(text, privacy: .public)")
                            typedText.append(text)
                            if typedText.count > 200 {
                                typedText = String(typedText.suffix(200))
                            }
                        }
                        lastKey = event
                    case .down:
                        lastKey = event
                    case .up:
                        break
                    }
                    inputInjector.inject(key: event)
                }
            case .audio:
                if let packet = try? IBWire.decodeAudio(frame) {
                    audioPacketCount += 1
                    if audioPacketCount == 1 || audioPacketCount % 100 == 0 {
                        Self.log.info("audio packets received: \(self.audioPacketCount) (\(packet.opusData.count) B, \(packet.sampleRate) Hz x \(packet.channels) ch, codec=\(packet.codec, privacy: .public))")
                    }
                    // Decode once, here, so every consumer (recorder,
                    // virtual mic, speaker) keeps seeing plain PCM.
                    var pcm = packet.opusData
                    if packet.codec == AudioPacket.codecOpus {
                        if opusDecoder == nil {
                            opusDecoder = IBOpusDecoder(sampleRate: 48_000)
                            if opusDecoder == nil {
                                Self.log.error("opus decoder unavailable — opus packets will be dropped")
                            }
                        }
                        guard let decoded = opusDecoder?.decode(packet: packet.opusData), !decoded.isEmpty else {
                            opusDropCount += 1
                            if opusDropCount == 1 || opusDropCount % 100 == 0 {
                                Self.log.warning("opus decode failed, packets dropped: \(self.opusDropCount)")
                            }
                            break
                        }
                        pcm = decoded
                    }
                    let pcmPacket = AudioPacket(
                        opusData: pcm,
                        sampleRate: packet.sampleRate,
                        channels: packet.channels,
                        timestampMicros: packet.timestampMicros
                    )
                    recorder.appendAudio(pcm)
                    micRing?.write(pcm)
                    audioPlayer.consume(pcmPacket)
                }
            case .featureControl:
                // Mac → iPhone direction only; ignore if we ever receive one.
                break
            case .featureState:
                if let snap = try? IBWire.decodeFeatureState(frame) {
                    Self.log.info("featureState: camera=\(snap.cameraOn) mic=\(snap.micOn) voice=\(snap.voiceOn) trackpad=\(snap.trackpadOn) keyboard=\(snap.keyboardOn) speaker=\(snap.speakerOn)")
                    featureState = snap
                    // The phone owns this toggle, so the Mac follows the
                    // echoed state rather than acting on the request twice.
                    if snap.speakerOn { startSpeakerCapture() } else { stopSpeakerCapture() }
                }
            case .ping:
                guard frame.payload.count == 8 else {
                    Self.log.warning("ping frame with malformed payload (\(frame.payload.count) bytes), skipping")
                    continue
                }
                let sentMicros = IBWire.decodePing(frame)
                // ANY ping arriving proves the link is alive, so the watchdog
                // is satisfied either way.
                lastPongAt = Date()
                guard pingProbe.isOwnEcho(sentMicros) else {
                    // A probe the iPhone originated, so the phone is the one
                    // waiting to measure. Echoing it is what lets the phone
                    // show latency at all — it cannot derive a round trip
                    // from a timestamp stamped with the Mac's clock.
                    //
                    // Crucially this must NOT fall through to the RTT maths
                    // below: subtracting the phone's timestamp from ours
                    // yields the CLOCK OFFSET between the two machines, which
                    // can be hours, and that number is what the menu bar
                    // would display.
                    self.connection?.send(content: IBWire.encodePing(sentMicros: sentMicros),
                                          completion: .contentProcessed { _ in })
                    break
                }
                guard let rttMs = pingProbe.roundTripMs(ofEcho: sentMicros, now: Date()) else { break }
                latencyHistory.append(rttMs)
                if latencyHistory.count > 30 {
                    latencyHistory.removeFirst(latencyHistory.count - 30)
                }
                // The **median**, not this sample. A single reading is a
                // measurement of one packet: it moves with whatever else the
                // Mac was doing, and a menu-bar number that flickers to 400 ms
                // because Spotlight woke up reads as "the link is bad" when the
                // link is fine. The Windows receiver has always reported the
                // median (`IBLatencyTracker.medianMs`), so showing the latest
                // value here also made the two receivers disagree about the same
                // measurement.
                latencyTracker.record(millis: rttMs)
                let reported = latencyTracker.medianMs ?? rttMs
                if case .streaming(let name, _) = state {
                    state = .streaming(name: name, latencyMs: reported)
                }
            case .appListRequest:
                publishMacApps(includeIcons: true)
            case .activateApp:
                if let request = try? IBWire.decodeActivateApp(frame) {
                    let status = activateAppAndRepublish(id: request.id,
                                                         windowTitle: request.windowTitle)
                    reply(request.requestId, status)
                }
            case .quitApp:
                if let request = try? IBWire.decodeQuitApp(frame) {
                    let status = quitApp(id: request.id, force: request.force)
                    reply(request.requestId, status)
                }
            case .systemCommand:
                if let command = try? IBWire.decodeSystemCommand(frame) {
                    let status = SystemCommandHandler.handle(command)
                    reply(command.requestId, status)
                    // "Show Desktop" from the switcher: also point the live
                    // mirror at the whole display, so the phone actually sees
                    // the desktop instead of staying on the old window.
                    if command.command == .showDesktop {
                        teardownVirtualDisplay()
                        screenStreamer?.captureDesktop()
                    }
                }
            case .screenControl:
                if let control = try? IBWire.decodeScreenControl(frame) {
                    handleScreenControl(control)
                }
            case .screenInput:
                if let input = try? IBWire.decodeScreenInput(frame) {
                    handleScreenInput(input)
                }
            case .windowListRequest:
                publishMacWindows()
            case .installedAppsRequest:
                publishInstalledApps()
            case .fileOffer:
                if let offer = try? IBWire.decodeFileOffer(frame) {
                    beginIncoming(offer)
                }
            case .fileChunk:
                appendIncoming(frame.payload)
            case .fileComplete:
                finishIncoming()
            case .clipboardSet:
                if let clip = try? IBWire.decodeClipboard(frame) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clip.text, forType: .string)
                    Self.log.info("clipboard received from iPhone (\(clip.text.count) chars)")
                }
            case .textCommand:
                if let msg = try? IBWire.decodeTextCommand(frame) {
                    applyTextCommand(msg.command)
                }
            default:
                break
            }
        }
    }

    private func handleMetadata(_ payload: Data) {
        do {
            let decoded = try JSONDecoder().decode(IBStreamMetadata.self, from: payload)
            metadata = decoded
            if let sps = decoded.sps { decoder.feedSPS(sps) }
            if let pps = decoded.pps { decoder.feedPPS(pps) }
            rekeyDirectConnection(realDeviceName: decoded.deviceName)
        } catch {
            Self.log.error("metadata decode failed: \(error, privacy: .public)")
        }
    }

    /// A direct-IP connection starts out keyed by a placeholder name
    /// ("iPhone (direct link)" or "host:port"), so its clientHello goes
    /// out WITHOUT the pairing token and the phone demands approval on
    /// every single reconnect. The metadata frame carries the device's
    /// real name — rebuild the Bonjour service name from it, move the
    /// token under that key, and teach the IP→name map, so the next
    /// direct dial is `paired: true` and reconnects silently.
    private func rekeyDirectConnection(realDeviceName: String) {
        guard connectedIsDirect, !realDeviceName.isEmpty else { return }
        let realName = "RemoteCrab — \(realDeviceName)"
        guard currentTokenKey != realName else { return }
        if let oldKey = currentTokenKey, let token = tokenStore[oldKey] {
            tokenStore.removeValue(forKey: oldKey)
            tokenStore[realName] = token
            saveTokens()
        }
        if let ip = connectedDirectIP {
            var map = Self.phoneNameByIP
            map[ip] = realName
            UserDefaults.standard.set(map, forKey: "remotecrab.phoneNameByIP")
        }
        currentTokenKey = realName
        connectedPhoneName = realName
        lastAttemptedPhoneName = realName
        if case .streaming = state {
            // Same rule on reconnect: a fresh tracker has no median yet, so
            // the first sample is the honest answer until there are enough for
            // one.
            state = .streaming(name: realName,
                               latencyMs: latencyTracker.medianMs
                                   ?? latencyHistory.last ?? 0)
        }
        Self.log.info("direct connection identified as \(realName, privacy: .public) — token re-keyed")
    }
}

/// UI-friendly mirror of the most recent `TouchEvent`, consumed by
/// the connection test window's trackpad board. Coordinates stay
/// normalized 0..1 (no screen remapping).
struct TouchVisual: Equatable, Sendable {
    let phase: TouchEvent.Phase
    let x: Float
    let y: Float
    let dx: Float
    let dy: Float
    let modifiers: UInt8
    /// When the Mac received the event — drives the idle fade-out.
    let receivedAt: Date

    init(event: TouchEvent, receivedAt: Date = Date()) {
        phase = event.phase
        x = event.x
        y = event.y
        dx = event.dx
        dy = event.dy
        modifiers = event.modifiers
        self.receivedAt = receivedAt
    }
}

struct DiscoveredPhone: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: String
    let port: UInt16
    /// The raw Bonjour service endpoint. Connecting to this directly lets
    /// Network.framework resolve SRV/A records itself; the string fields
    /// above are for display and the pre-Bonjour fallback path only.
    let serviceEndpoint: NWEndpoint?

    static func == (lhs: DiscoveredPhone, rhs: DiscoveredPhone) -> Bool {
        lhs.id == rhs.id
    }

    /// Display-safe endpoint string. Bonjour endpoint descriptions escape
    /// non-alphanumeric bytes as `\DDD` (decimal) — e.g. a space shows up
    /// as `\032` — so decode them back to UTF-8 before showing the string
    /// in the UI. Direct-IP endpoints contain no escapes and pass through.
    var displayEndpoint: String {
        Self.unescapingBonjourEscapes(endpoint)
    }

    static func unescapingBonjourEscapes(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = Data()
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\",
               let j = s.index(i, offsetBy: 1, limitedBy: s.endIndex),
               let k = s.index(j, offsetBy: 3, limitedBy: s.endIndex),
               let byte = UInt8(s[j..<k]) {
                out.append(byte)
                i = k
            } else {
                out.append(contentsOf: s[i].utf8)
                i = s.index(after: i)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension ReceiverSession.State {
    /// Single source of truth for rendering connection state as the
    /// shared status pill, so the menu bar popover, control panel,
    /// preview window and connection test all show the same thing.
    var statusPillStatus: IBStatusPill.Status {
        switch self {
        case .searching:            return .searching
        case .connecting:           return .connecting
        case .handshaking:          return .connecting
        case .awaitingApproval:     return .connecting
        case .streaming(_, let ms): return .connected(latencyMs: ms)
        case .error:                return .disconnected(reason: "Connection lost")
        }
    }

    /// The phone name carried by in-flight / live states, if any — the
    /// UI shows this instead of guessing from the discovery list.
    var phoneName: String? {
        switch self {
        case .connecting(let name),
             .handshaking(let name),
             .awaitingApproval(let name): return name
        case .streaming(let name, _):     return name
        case .searching, .error:          return nil
        }
    }
}