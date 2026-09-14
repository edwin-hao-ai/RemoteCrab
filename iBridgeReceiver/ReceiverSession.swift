import AppKit
import Foundation
import Network
import os
import SwiftUI
import VideoToolbox
import ApplicationServices
import iBridgeCore

/// The Mac-side counterpart to iOS `CaptureEngine`. Browses for the
/// Bonjour service, opens the first connection it sees, decodes H.264
/// frames via VideoToolbox, dispatches touch / key / audio events
/// to their respective handlers, and republishes the latest decoded
/// frame for the SwiftUI preview view.
@MainActor
final class ReceiverSession: ObservableObject {

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
    private var touchEventCount = 0
    private var keyEventCount = 0

    /// Latest feature-state snapshot from the iPhone. nil until the
    /// first `featureState` frame arrives (older iOS builds never
    /// send one — the UI must treat nil as "remote control unavailable").
    @Published private(set) var featureState: FeatureStateSnapshot?

    /// Running regular apps published to the iPhone's app switcher.
    @Published private(set) var macApps: [IBAppInfo] = []

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
    private static let log = Logger(subsystem: "com.ibridge", category: "receiver")

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

    private struct IncomingFile {
        let id: String
        let url: URL
        let handle: FileHandle
        var received: Int64
        let declared: Int64
    }
    private var incoming: IncomingFile?

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

        // Keep the iPhone's app switcher in sync with launches,
        // terminations and frontmost changes.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publishMacApps() }
            }
        }
    }

    // MARK: - App switcher (Mac → iPhone)

    /// Send the current regular-app list to the iPhone. No-op unless a
    /// session owner is established.
    func publishMacApps() {
        guard sessionGranted, let connection, connection.state == .ready else { return }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> IBAppInfo in
                let bid = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                return IBAppInfo(id: bid,
                                 name: app.localizedName ?? bid,
                                 pid: app.processIdentifier,
                                 isActive: app.isActive)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        macApps = apps
        Self.log.info("published \(apps.count, privacy: .public) apps to iPhone")
        if let data = try? IBWire.encode(appList: IBAppList(apps: apps)) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func activateApp(id: String) {
        let app: NSRunningApplication?
        if id.hasPrefix("pid:"), let pid = Int32(id.dropFirst(4)) {
            app = NSRunningApplication(processIdentifier: pid_t(pid))
        } else {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        }
        guard let app else {
            Self.log.info("activateApp: not running (\(id, privacy: .public))")
            return
        }
        app.activate()
        Self.log.info("activated app \(app.localizedName ?? id, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.publishMacApps()
        }
    }

    // MARK: - Recording

    /// Toggle recording of the live video + audio to `~/Movies/iBridge`.
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
        MacPaths.directory("Downloads/Familiar")
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
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
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

    // MARK: - Identity

    private static func loadMacId() -> String {
        let key = "ibridge.mac.id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static func loadMacName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func loadTokens() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "ibridge.mac.tokens"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveTokens() {
        guard let data = try? JSONEncoder().encode(tokenStore) else { return }
        UserDefaults.standard.set(data, forKey: "ibridge.mac.tokens")
        pairedPhones = tokenStore.keys.sorted()
    }

    // MARK: - Discovery

    func start() {
        browser.start(serviceType: IBServiceType.tcp) { [weak self] phones in
            Task { @MainActor in
                self?.handleDiscovered(phones)
            }
        }
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
        guard connection == nil, !autoConnectSuppressed else { return }
        // Bidirectional pairing: the Mac never connects to an iPhone it
        // hasn't paired with — the user picks one from the Devices list
        // and the iPhone shows its approval card. A phone this Mac holds
        // a token for was approved on both sides already, so it may
        // connect on sight (this is also the reconnect-after-drop path).
        if let phone = phones.first(where: { tokenStore[$0.name] != nil }) {
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

    private func connect(to phone: DiscoveredPhone) {
        connection?.cancel()
        connection = nil
        sessionGranted = false
        suppressReconnect = false
        slowRetryTask?.cancel()
        slowRetryTask = nil
        currentTokenKey = phone.name
        lastAttemptedPhoneName = phone.name

        state = .connecting(name: phone.name)
        Self.log.info("connecting to \(phone.name, privacy: .public) (serviceEndpoint: \(phone.serviceEndpoint != nil, privacy: .public))")

        let conn: NWConnection
        if let serviceEndpoint = phone.serviceEndpoint {
            conn = NWConnection(to: serviceEndpoint, using: .tcp)
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(phone.endpoint),
                port: NWEndpoint.Port(rawValue: phone.port) ?? .any,
                using: NWParameters.tcp
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
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        Self.log.info("connection state: \(String(describing: newState), privacy: .public)")
        switch newState {
        case .ready:
            // TCP is up but we are NOT the session owner yet: identify
            // ourselves and wait for the iPhone's ownership decision.
            if let connection { sendClientHello(on: connection) }
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
            clearConnectionState()
            scheduleReconnect()
        case .cancelled:
            stopPingLoop()
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
        let hello = IBClientHello(name: macName, id: macId, token: token, appVersion: version)
        do {
            let data = try IBWire.encode(clientHello: hello)
            Self.log.info("clientHello sent (paired: \(token != nil, privacy: .public))")
            conn.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            Self.log.error("clientHello encode failed: \(error, privacy: .public)")
        }
    }

    private func handleSessionReply(_ reply: IBSessionReply) {
        Self.log.info("sessionReply: \(reply.result.rawValue, privacy: .public) owner=\(reply.ownerName ?? "-", privacy: .public)")
        switch reply.result {
        case .accepted:
            suppressReconnect = false
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
            if let connection { startPingLoop(on: connection) }
            publishMacApps()
            // Headless e2e: apply a text transform to whatever is
            // selected on the Mac (point TextEdit at a scratch doc and
            // select-all first).
            if let name = ProcessInfo.processInfo.environment["IBRIDGE_E2E_TEXT_COMMAND"],
               let command = IBTextCommand(rawValue: name) {
                Task { @MainActor [weak self] in
                    // 10 s gives the tester time to focus a text field
                    // and select something after the session connects.
                    try? await Task.sleep(for: .seconds(10))
                    self?.applyTextCommand(command)
                }
            }
            // Headless e2e: record a few seconds of the live stream.
            if ProcessInfo.processInfo.environment["IBRIDGE_E2E_RECORD"] == "1" {
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
                state = .awaitingApproval(name: name)
            }

        case .busy:
            sessionGranted = false
            suppressReconnect = true
            stopPingLoop()
            state = .error(reply.ownerName.map { IBLocale.Error.iphoneBusy($0) }
                           ?? IBLocale.Error.iphoneBusyUnknown)
            scheduleSlowRetry()

        case .denied:
            sessionGranted = false
            suppressReconnect = true
            stopPingLoop()
            state = .error(IBLocale.Error.connectionDenied)
            // Manual retry only — don't nag a user who tapped Deny.
        }
    }

    /// UI action: clear a busy/denied state and try again immediately.
    func retryNow() {
        suppressReconnect = false
        autoConnectSuppressed = false
        slowRetryTask?.cancel()
        slowRetryTask = nil
        state = .searching
        if let phone = preferredPhone() ?? discovered.first { connect(to: phone) }
    }

    /// One polite retry 30 s after being refused, then stop.
    private func scheduleSlowRetry() {
        slowRetryTask?.cancel()
        slowRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.suppressReconnect else { return }
            self.retryNow()
        }
    }

    private func startPingLoop(on connection: NWConnection) {
        stopPingLoop()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self, weak connection] _ in
            guard let connection, connection.state == .ready else { return }
            let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
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
    /// re-arms. Never auto-dials a phone we haven't paired with.
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
        return discovered.first(where: { tokenStore[$0.name] != nil })
    }

    private func currentPhoneName() -> String? {
        connectedPhoneName
    }

    /// Wipe every piece of per-connection state when the link goes
    /// away: the feature snapshot, the test-window mirrors, and the
    /// stream state (metadata / last frame / latency) so no window
    /// keeps showing stale evidence of a dead connection.
    private func clearConnectionState() {
        featureState = nil
        connection = nil
        connectedPhoneName = nil
        sessionGranted = false
        try? incoming?.handle.close()
        incoming = nil
        metadata = nil
        latestFrame = nil
        latencyHistory = []
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
                    if keyEventCount == 1 || keyEventCount % 20 == 0 {
                        Self.log.info("key events received: \(self.keyEventCount) (action=\(String(describing: event.action), privacy: .public) text=\(event.text ?? "", privacy: .public))")
                    }
                    switch event.action {
                    case .text:
                        if let text = event.text {
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
                        Self.log.info("audio packets received: \(self.audioPacketCount) (\(packet.opusData.count) B, \(packet.sampleRate) Hz x \(packet.channels) ch)")
                    }
                    recorder.appendAudio(packet.opusData)
                    micRing?.write(packet.opusData)
                    audioPlayer.consume(packet)
                }
            case .featureControl:
                // Mac → iPhone direction only; ignore if we ever receive one.
                break
            case .featureState:
                if let snap = try? IBWire.decodeFeatureState(frame) {
                    Self.log.info("featureState: camera=\(snap.cameraOn) mic=\(snap.micOn) voice=\(snap.voiceOn) trackpad=\(snap.trackpadOn) keyboard=\(snap.keyboardOn)")
                    featureState = snap
                }
            case .ping:
                guard frame.payload.count == 8 else {
                    Self.log.warning("ping frame with malformed payload (\(frame.payload.count) bytes), skipping")
                    continue
                }
                let sentMicros = IBWire.decodePing(frame)
                let nowMicros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
                let rttMs = Int((nowMicros &- sentMicros) / 1_000)
                latencyHistory.append(rttMs)
                if latencyHistory.count > 30 {
                    latencyHistory.removeFirst(latencyHistory.count - 30)
                }
                if case .streaming(let name, _) = state {
                    state = .streaming(name: name, latencyMs: rttMs)
                }
            case .appListRequest:
                publishMacApps()
            case .activateApp:
                if let request = try? IBWire.decodeActivateApp(frame) {
                    activateApp(id: request.id)
                }
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
        } catch {
            Self.log.error("metadata decode failed: \(error, privacy: .public)")
        }
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