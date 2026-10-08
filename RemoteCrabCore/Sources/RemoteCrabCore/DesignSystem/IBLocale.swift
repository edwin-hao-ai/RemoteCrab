import Foundation

/// Centralized user-facing strings for RemoteCrab.
///
/// Every UI string in both apps (iOS Capture + Mac Receiver) pulls from
/// here. The English source text doubles as the lookup key and lives in
/// `Sources/RemoteCrabCore/Resources/Localizable.xcstrings` (en source +
/// zh-Hans translations), resolved against `Bundle.module` so both apps
/// follow the system language. Add a language by adding a locale to that
/// catalog — no Swift changes required.
///
/// Technical readouts (fps / Mbps / ms / resolution labels / codec names)
/// are deliberately left as plain literals in code: they are locale-neutral
/// and rendered in SF Mono.
///
/// - Note: values are resolved once per process. A system-language change
///   takes effect on next launch (standard for macOS / iOS apps).
private func IBL(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

public enum IBLocale {

    /// Localize a string that is **data**, not a literal — e.g. the
    /// context-mode action labels, which come from `ContextProfiles` and so
    /// cannot be wrapped in `IBL(...)` at the call site.
    ///
    /// `Text(LocalizedStringKey(label))` is NOT equivalent: it looks the key
    /// up in `Bundle.main`, but the catalog lives in this package, so the
    /// lookup silently misses and the raw English key is shown — translations
    /// existed and still never appeared. Same class as lesson 8's corollary.
    public static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
    public enum Launcher {
        public static let title = IBL("Applications")
        public static let searchPlaceholder = IBL("Search apps")
        public static let empty = IBL("No apps listed yet")
        public static let hint = IBL("Apps reported by the connected computer")
        /// Shown while the receiver enumerates and rasterises its app list
        /// — a cold Mac needs seconds, and "no apps yet" during that window
        /// is the one thing this surface must never say.
        public static let loading = IBL("Asking your computer for its apps…")
        /// The request went out and nothing came back — a dead link or a
        /// receiver that predates the frame, not an empty list.
        public static let noAnswer = IBL("Your computer didn’t answer")
        public static let noAnswerHint = IBL("Check that RemoteCrab Receiver is running and up to date, then try again.")
        public static let offlineHint = IBL("Reconnect, then try again.")
    }

    /// App-window mirror surface (full-screen chrome + coach mark).
    public enum Mirror {
        public static let title = IBL("App window mirror")
        public static let guideTitle = IBL("Mirror guide")
        public static let guideBody = IBL("Tap to click · Two-finger scroll · Pinch to zoom")
        public static let gotIt = IBL("Got it")
        public static let followFrontmost = IBL("Follow frontmost app")
        /// Window-picker (mirror bottom chrome) — the menu header.
        public static let windowPicker = IBL("Show which window")
        /// Window-picker — the auto mode row (checkmarked while following).
        public static let autoFollow = IBL("Auto — follow current app")
        /// Window-picker — accessibility state when a window is held.
        public static let pinned = IBL("Pinned")
        /// Window-picker — first-use coach-mark line.
        public static let windowPickerHint = IBL("Tap the window icon to pin one window, or follow the current app.")
        public static let extendDisplay = IBL("Extended Display")
        public static let window = IBL("Window")
        public static let computer = IBL("Computer")
        public static let fitWindow = IBL("Fit window")
        public static let fillView = IBL("Fill view")
        public static let toggleZoom = IBL("Toggle zoom")
        public static let showControls = IBL("Show controls")
        public static let hideControls = IBL("Hide controls")
    }

    /// Mac 自动更新（Sparkle）相关文案。
    public enum Update {
        public static let checkForUpdates = IBL("Check for Updates…")
        public static let restartToUpdate = IBL("Restart to Update")
        public static let autoUpdate = IBL("Automatically check for updates")
        public static let autoUpdateDescription = IBL("Download and install new versions in the background.")
    }

    /// Mac notification relay (Mac Preferences; iOS list lives in Task 4).
    public enum Notify {
        public static let section = IBL("Notifications")
        public static let forward = IBL("Forward notifications to iPhone")
        public static let forwardHint = IBL("Relay non-denylisted Mac notification banners to your iPhone")
        public static let forwardCaption = IBL("Only banners that appear while you're connected are forwarded. Do Not Disturb / Focus notifications are not captured.")
        public static let addPlaceholder = IBL("App name to exclude")
        public static let add = IBL("Add")
        public static let remove = IBL("Remove")
        public static let denylistEmpty = IBL("No excluded apps")
        public static let denylistFooter = IBL("Notifications from these apps are never forwarded. Matching is case-insensitive on the app's display name.")

        // iOS inbox (relayed notifications list).
        public static let clear = IBL("Clear all")
        public static let empty = IBL("No notifications yet")
        public static let emptyHint = IBL("Notifications from your computer appear here.")
    }

    public enum App {
        public static let name = IBL("RemoteCrab")
        public static let tagline = IBL("Computer receiver")
        public static let captureName = IBL("RemoteCrab")
        public static let receiverName = IBL("RemoteCrab Receiver")
        /// Overflow-menu button label.
        public static let more = IBL("More")
        public static let quit = IBL("Quit RemoteCrab")
        /// Root-window "running" placeholder (Mac).
        public static let running = IBL("RemoteCrab is running")
        public static let runningHint = IBL("Open the control panel from the menu bar icon.")
    }

    public enum Status {
        public static let looking = IBL("LOOKING")
        public static let connecting = IBL("CONNECTING")
        /// Listener is up and healthy, simply no Mac has dialed in yet —
        /// distinct from "connecting" so a long wait doesn't read as
        /// a stuck progress state.
        public static let waiting = IBL("WAITING")
        public static let live = IBL("LIVE")
        public static let offline = IBL("OFFLINE")
        public static let reconnecting = IBL("RECONNECTING")
        /// Calm pre-stream state on the iPhone (nothing started, nothing wrong).
        public static let ready = IBL("READY")

        public static func latency(_ ms: Int) -> String { "\(ms) ms" }

        /// Subtitle shown on disabled feature toggles when no iPhone
        /// is connected (writes would be silently dropped).
        public static let connectIPhoneFirst = IBL("Connect an iPhone first")
    }

    public enum Permission {
        public static let camera = IBL("Camera Access")
        public static let cameraReason = IBL("RemoteCrab turns your iPhone's camera into a high-quality webcam for your computer. We use it in real time — nothing is recorded or uploaded.")

        public static let microphone = IBL("Microphone Access")
        public static let microphoneReason = IBL("RemoteCrab can stream your iPhone's microphone to your computer. This is optional — toggle it off in the camera screen anytime.")

        public static let localNetwork = IBL("Local Network Access")
        public static let localNetworkReason = IBL("RemoteCrab uses Bonjour to find your computer on the same WiFi. Without this, the two devices can't talk to each other.")

        public static let speech = IBL("Speech Recognition")
        public static let speechReason = IBL("Hold the voice button to dictate text into your computer. Recognition happens on your iPhone — audio never leaves your device for this feature.")

        public static let photos = IBL("Photos Access")
        public static let photosReason = IBL("RemoteCrab can send your latest screenshots straight to the computer. Only the screenshots you send are read — nothing is uploaded.")

        public static let accessibility = IBL("Accessibility Permission")
        public static let accessibilityReason = IBL("We need Accessibility to drive your Mac's cursor and keyboard from your iPhone.")

        public static let allow = IBL("Continue")
        public static let notNow = IBL("Not now")
        public static let granted = IBL("Granted")
        /// Local-network probe: the system keeps the dialog up past our
        /// timeout, so we can't claim a result — neutral phrasing.
        public static let checkComplete = IBL("Check complete — if iOS shows a prompt, tap Allow")
        public static let denied = IBL("Denied — you can enable this later in Settings")
        public static let openSystemSettings = IBL("Open System Settings")
        public static let recheck = IBL("Re-check")
        public static let accessibilityRequired = IBL("Accessibility permission required")
        public static let accessibilityGranted = IBL("Accessibility granted")

        public static let screenRecording = IBL("Screen Recording")
        public static let notGranted = IBL("Not granted")
        public static let screenRecordingReason = IBL("We need Screen Recording to mirror a Mac window to your iPhone. macOS adds RemoteCrab to the list when you tap the button — switch it on, then restart RemoteCrab.")
    }

    public enum Onboarding {
        public static let heroTitle = IBL("RemoteCrab")
        public static let heroBody = IBL("Turn your iPhone into a camera, microphone, trackpad and keyboard for your computer — over WiFi.")
        public static let permissionsTitle = IBL("We need a few permissions")
        // Must list the SAME set the request flow asks for (camera, microphone,
        // speech, photos, local network) — it used to name three while the
        // illustration drew four and the flow asked five.
        public static let permissionsBody = IBL("RemoteCrab needs your camera, microphone, speech, photos, and local network. We only ever send data to your computer — nothing leaves your WiFi.")
        public static let pairTitle = IBL("Connect to your computer")
        public static let pairBody = IBL("Download and open RemoteCrab Receiver on your computer, then tap Continue. They'll find each other automatically.")
        public static let getStarted = IBL("Get Started")
        public static let skip = IBL("Skip")
        public static let nextBtn = IBL("Continue")
        public static let allowAndConnect = IBL("Continue")
        /// Pair-page illustration: both devices must share a network.
        public static let sameWiFi = IBL("Same WiFi")

        /// Permissions-page illustration cards.
        public static let permCameraTitle = IBL("Camera")
        public static let permCameraDesc = IBL("Live iPhone feed to your computer")
        public static let permMicTitle = IBL("Microphone")
        public static let permMicDesc = IBL("Stream iPhone mic to your computer's speakers")
        /// Reuses the "Speech Recognition" string the request flow uses, so the
        /// illustration and the flow name the same thing.
        public static let permSpeechTitle = IBL("Speech Recognition")
        public static let permSpeechDesc = IBL("Hold the voice button to dictate into your computer")
        public static let permNetworkTitle = IBL("Local Network")
        public static let permNetworkDesc = IBL("Discover & connect to your computer")
        public static let permPhotoTitle = IBL("Photos")
        public static let permPhotoDesc = IBL("Send recent screenshots to your computer")
    }

    public enum Mode {
        public static let camera = IBL("Camera")
        public static let trackpad = IBL("Trackpad")
        public static let keyboard = IBL("Keyboard")
        public static let touchpad = IBL("Touchpad")  // alias

        public static func label(_ mode: String) -> String { IBL(mode) }
    }

    public enum Mic {
        public static let on = IBL("Mic on")
        public static let off = IBL("Mic off")
        /// The three states of the combined microphone / speaker control.
        /// These are the CHECKMARK LABELS in that menu, and they double as
        /// the value VoiceOver announces — a sighted user reads a checkmark
        /// where a screen-reader user needs a word, so the two must be the
        /// same string.
        public static let modeOff = IBL("Off")
        public static let modeMicrophone = IBL("Microphone")
    }

    /// "Use the iPhone as the speaker": the computer's audio plays out of
    /// this phone. Named as an action a person would recognise rather than as
    /// a codec or a channel.
    public enum Speaker {
        public static let modeSpeaker = IBL("Speaker")
        /// First-run explanation. The top bar carries no text labels at all,
        /// so without this the capability is invisible until you already know
        /// to look for it.
        public static let title = IBL("Play computer sound")
        public static let hint = IBL("Play the computer's sound out of this phone's speaker. The computer's own speakers go quiet while it is on, and come back when you switch off.")
        public static let enabling = IBL("Turning on the phone speaker…")
        public static let on = IBL("Speaker on")
        public static let off = IBL("Speaker off")
        public static let listeningCheck = IBL("If you hear nothing, check this phone's volume — the computer is not playing through its own speakers right now.")
        // The audio tap's failures. Short on purpose: this text is a menu
        // subtitle, and the action it needs ("Finish Setup…") is a row of its
        // own at the top of the very same menu. A three-sentence paragraph in a
        // menu row is what made two rows overlap in the first place.
        public static let tapNeedsScreenRecording = IBL("Screen Recording is needed to play the Mac's audio on the iPhone. Use “Finish Setup…” above.")
        public static let tapUnavailable = IBL("This Mac did not provide an audio tap (error %d). Update macOS and try again.")
        public static let tapNotReadable = IBL("The audio tap could not be opened for reading (error %d). Reconnect or restart the Mac's audio and try again.")
        public static let tapAlreadyRunning = IBL("Already capturing.")
        public static let notConnectedNoAudio = IBL("Not connected — the phone cannot play audio from a computer that is not connected.")
        /// The Mac menu row for this feature is a *status*, not a control:
        /// the phone is where the user decides whether their computer's audio
        /// should reach it, and a switch on the other machine is a second
        /// place to look for the same decision. This says so, and says what
        /// the state is, because a row that only says where to go elsewhere
        /// has not told the user anything about now.
        public static let controlledOnPhone = IBL("On — switch it off on your iPhone")
        public static let controlledOnPhoneOff = IBL("Off — switch it on from your iPhone's sound menu")
        public static let connectPhoneFirst = IBL("Connect your iPhone to switch this on")
    }

    /// iOS connection sheet (Bonjour readout + stream toggle).
    public enum Connection {
        public static let info = IBL("Connection")
        public static let address = IBL("Address")
        public static let connectManually = IBL("Connect Manually…")
        public static let connect = IBL("Connect")
        public static let cancel = IBL("Cancel")
        public static let manualHint = IBL("Enter the iPhone's address shown on its Connection screen, e.g. 192.168.1.5:8765.")
        public static let bonjourService = IBL("Bonjour Service")
        public static let awaitingApprovalTitle = IBL("The iPhone is waiting for you")
        public static let awaitingApprovalNamed = IBL("Tap Allow on the iPhone to connect")
        public static let awaitingApprovalGeneric = IBL("The iPhone is waiting for approval to connect")
        public static let streamSection = IBL("Stream")
        public static let startStreaming = IBL("Start streaming")
        public static let stopStreaming = IBL("Stop streaming")
        public static let starting = IBL("Starting…")

        /// Devices section (bidirectional pairing): the Mac lists the
        /// iPhones it discovered and connects only when the user picks
        /// one — mirroring the iPhone's approval card.
        public static let devicesSection = IBL("DEVICES")
        public static let disconnect = IBL("Disconnect")
        public static let pairedPhones = IBL("Paired iPhones")
        public static let noPairedPhones = IBL("No paired iPhones yet")
        public static let forget = IBL("Forget")
        public static let pairedBadge = IBL("Paired — connects automatically")
        public static let pairedPhonesFooter = IBL("Paired iPhones connect automatically when they appear on the network. Forget one to require approval again.")
        /// Display name for a phone reached via the direct-IP fallback
        /// (Bonjour blocked) before its real name is known.
        public static let directPhone = IBL("iPhone (direct link)")

        /// iOS connection-sheet Bonjour/stream readout labels.
        public static let type = IBL("Service Type")
        public static let domain = IBL("Domain")
        public static let status = IBL("Status")
        public static let resolution = IBL("Resolution")
        public static let bitrate = IBL("Bitrate")
        /// Connection-sheet target section: which Mac this iPhone serves.
        public static let macSection = IBL("Mac")
        public static let notConnected = IBL("Not connected")
    }

    /// Hold-to-talk voice card states.
    public enum Voice {
        public static let listening = IBL("Listening…")
        public static let sent = IBL("Sent")
        public static let holdToTalk = IBL("Hold to talk")
        public static let releaseToSend = IBL("Release to send")
        /// Shown while a routine recognizer hiccup (or an audio-session
        /// interruption) is being recovered. The hold is still active —
        /// the user must not release and press again.
        public static let recovering = IBL("Still listening…")
        /// Voice card error state. The raw recognizer error goes to
        /// os_log, never to the UI.
        public static let stopped = IBL("Voice input stopped")
    }

    /// Settings → Labs (experimental gestures, default off).
    public enum Labs {
        public static let title = IBL("Labs")
        public static let airMouse = IBL("Air mouse")
        public static let wheelScroll = IBL("Wheel scrolling")
        public static let footer = IBL("Experimental gestures. Wheel scrolling works inline — just draw a circle on the trackpad. Air mouse: tap the gyroscope button on the trackpad, then tilt your iPhone.")
        public static let airMouseTutorial = IBL("Air mouse is ON — tilt your iPhone to move the cursor; hold a tilt to keep moving. Tap the button again to stop.")
        public static let wheelTutorial = IBL("Wheel scrolling is ON — draw circles on the trackpad to scroll (clockwise = down). Tap the button again to exit.")
    }

    /// Camera-preview placeholder (eyebrow style — rendered in caps
    /// with `ibEyebrowTracking()`).
    public enum Capture {
        public static let cameraOff = IBL("CAMERA IS OFF")
        public static let cameraStarting = IBL("STARTING CAMERA…")
        public static let turnCameraOn = IBL("TURN ON")
    }

    public enum Settings {
        public static let title = IBL("Settings")
        public static let done = IBL("Done")
        public static let general = IBL("General")
        public static let streaming = IBL("Streaming")
        public static let video = IBL("Video")
        public static let audio = IBL("Audio")
        public static let network = IBL("Network")
        public static let about = IBL("About")
        public static let accessibility = IBL("Accessibility")
        public static let permissions = IBL("Permissions")
        public static let replayOnboarding = IBL("Replay Onboarding")
        /// Camera-extension section footer (Preferences).
        public static let cameraExtensionFooter = IBL("Lets other apps use your iPhone as a webcam. Runs from /Applications only. Re-register after moving or updating the app.")

        public enum Resolution: String, CaseIterable, Identifiable {
            case p720  = "720p"
            case p1080 = "1080p"
            case p2160 = "4K"
            public var id: String { rawValue }
            public var localizedLabel: String { rawValue }
        }

        public enum FrameRate: Int, CaseIterable, Identifiable {
            case fps24 = 24
            case fps30 = 30
            case fps60 = 60
            public var id: Int { rawValue }
            public var localizedLabel: String { "\(rawValue) fps" }
        }

        public enum AudioQuality: String, CaseIterable, Identifiable {
            case voice   = "Voice (16 kHz)"
            case std     = "Standard (48 kHz)"
            case high    = "High fidelity (48 kHz · lossless)"
            public var id: String { rawValue }
            public var localizedLabel: String { rawValue }
        }

        public enum CameraPosition: String, CaseIterable, Identifiable {
            case front = "Front"
            case back  = "Back"
            public var id: String { rawValue }
            public var localizedLabel: String { rawValue }
        }

        public static func launchAtLogin(_ on: Bool) -> String {
            on ? IBL("Open RemoteCrab at login") : IBL("Don't open at login")
        }
        public static let launchAtLoginDescription = IBL("Start RemoteCrab Receiver automatically when you log in.")
        public static let peerToPeer = IBL("Direct Wi-Fi (peer-to-peer)")

        public static let versionLabel = IBL("Version")
        public static let buildLabel = IBL("Build")
        public static let builtFor = IBL("Built for")
        public static let copyrightLabel = IBL("© RemoteCrab. Local-first, no cloud, no analytics.")

        public static let resetAccessibility = IBL("Re-request Accessibility permission")
        public static let openAtLogin = IBL("Open at Login")

        /// iOS settings section footers.
        public static let connectionFooter = IBL("RemoteCrab streams over your local WiFi using Bonjour. No data ever leaves your network.")
        public static let streamFooter = IBL("Higher resolutions and frame rates use more WiFi bandwidth. 1080p / 30 fps is the recommended balance.")
        public static let inputFooter = IBL("Trackpad sensitivity: 1 = slowest, 5 = fastest. Default is 3.")

        public static let cameraExtension = IBL("Camera Extension")
        public static let activate = IBL("Activate")
        public static let sysexNotInstalled = IBL("Not installed")
        public static let sysexAwaitingApproval = IBL("Waiting for approval in System Settings")
        public static let sysexActive = IBL("Active")
        public static let sysexFailed = IBL("Activation failed")
        public static let sysexRepairing = IBL("Re-registering…")

        /// One-click camera-extension guide card.
        public static let cameraExtensionTitle = IBL("Use your iPhone as a webcam")
        public static let cameraExtensionGuide = IBL("RemoteCrab installs a small camera extension so FaceTime, Zoom, Photo Booth, OBS and other apps can select “RemoteCrab Camera”. macOS asks you to approve it once.")
        public static let enableCameraExtension = IBL("Enable Camera Extension")
        public static let openExtensions = IBL("Open System Settings")
        public static let reRegister = IBL("Re-register")
        public static let cameraExtensionActiveHint = IBL("RemoteCrab Camera now appears in your apps' camera lists.")
        public static let cameraExtensionGenericError = IBL("Couldn't set up the camera extension.")

        /// iOS settings input section.
        public static let input = IBL("Input")
        public static let keepScreenOn = IBL("Keep screen on while streaming")
        public static func sensitivity(_ value: Int) -> String {
            String(format: IBL("Sensitivity %lld"), value)
        }
        public static let scrollSpeed = IBL("Scroll Speed")
        public static let naturalScroll = IBL("Natural Scrolling")
        public static let naturalScrollHint = IBL("Content follows your fingers, like the computer's natural scrolling. Turn off if it uses the classic direction.")
        public static let backgroundKeepAlive = IBL("Stay connected in the background")
        public static let backgroundKeepAliveHint = IBL("Keeps RemoteCrab reachable when you switch apps or lock the screen, so your computer can always connect. Plays silent audio.")
        public static let hapticStrength = IBL("Haptic Feedback")
        public static let hapticHint = IBL("iOS pauses haptics while the microphone or hold-to-talk is active.")
        public static let hapticOff = IBL("Off")
        public static let hapticLight = IBL("Light")
        public static let hapticNormal = IBL("Normal")
        public static let hapticStrong = IBL("Strong")
        public static let testHaptics = IBL("Test haptics")
        public static let testHapticsHint = IBL("If you don't feel this, turn on Settings → Sounds & Haptics → System Haptics (UIFeedbackGenerator only plays when it's on).")
        public static let privacyPolicy = IBL("Privacy Policy")
        /// About-section link to the Mac receiver download page (vgoapp.com).
        public static let downloadMac = IBL("Download the desktop app")
    }

    public enum ModifierKey: String, CaseIterable, Identifiable {
        case control = "⌃"
        case option  = "⌥"
        case command = "⌘"
        case shift   = "⇧"
        public var id: String { rawValue }
        public var localizedLabel: String { rawValue }
    }

    public enum TouchpadHint {
        public static let drag = IBL("Drag")
        public static let dragDescription = IBL("Move cursor")
        public static let tap = IBL("Tap")
        public static let tapDescription = IBL("Left click")
        public static let twoFinger = IBL("Two fingers")
        public static let twoFingerDescription = IBL("Scroll / right click")
    }

    /// First-run coach marks on the full-screen trackpad surface.
    public enum Coach {
        public static let title = IBL("Gestures")
        public static let dismiss = IBL("Got it")

        /// Which surface a section describes. The two surfaces share a
        /// finger-count vocabulary — three fingers means middle-click on the
        /// trackpad and free panning in the mirror — so every heading names
        /// its surface instead of relying on the reader remembering which
        /// screen they are on.
        public static let surfaceTrackpad = IBL("Touchpad")
        public static let surfaceMirror = IBL("App window mirror")

        public static let sectionMove = IBL("Move & click")
        public static let dragMove = IBL("Drag to move the cursor")
        public static let tapClick = IBL("Tap to click")

        public static let sectionScroll = IBL("Scroll & zoom")
        public static let twoFingerScroll = IBL("Two fingers to scroll — with momentum")
        public static let twoFingerRightClick = IBL("Two-finger tap for right-click")
        public static let pinchZoom = IBL("Pinch to zoom the app on the Mac — it acts as ⌘ + scroll, so it zooms whatever the front app zooms")

        public static let sectionDrag = IBL("Select & drag")
        public static let doubleTapHoldDrag = IBL("Hold still, or double-tap and hold, then move to drag")
        public static let clutchDrag = IBL("Lift at the edge and touch down again in a moment to keep dragging")

        public static let sectionFingers = IBL("Three & four fingers")
        public static let threeFingerTap = IBL("Three-finger tap for middle-click")
        public static let threeFingerSwipe = IBL("Three or four fingers up for Mission Control, sideways to switch desktops")
        public static let forceClick = IBL("Press hard for right-click")

        public static let sectionKeys = IBL("Modifiers & keys")
        public static let modifierBar = IBL("Lock ⌃⌥⌘⇧ — they ride on every tap and gesture")
        public static let shiftSelect = IBL("With ⇧ locked: tap the start, then the end, to select everything between")
        public static let quickKeys = IBL("⌫ , . ⏎ sit under your thumb for quick fixes")

        // MARK: - Windows wording
        //
        // The gesture reference is read *while connected*, and these five
        // rows named things a PC does not have: three keys that are not on
        // its keyboard, "Mission Control", and "the Mac". A reference that
        // describes the wrong machine is worse than one that says less —
        // the reader has no way to tell which parts to trust.
        //
        // Functions rather than a `platform:` parameter on each string so a
        // caller cannot forget: `CoachText.modifierBar` has to be spelled
        // out at every use, and there is a test that walks both platforms.

        /// ⌃⌥⌘⇧ on a Mac; Ctrl / Alt / ⊞ / Shift on a PC.
        public static func modifierBar(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? windowsModifierBar : modifierBar
        }

        /// Mission Control is macOS. Windows calls it Task View.
        public static func threeFingerSwipe(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? windowsThreeFingerSwipe : threeFingerSwipe
        }

        /// ⌘ + scroll on a Mac is Ctrl + scroll on a PC — the receiver
        /// collapses the two modifier bits, which is why this is a
        /// reword and not a different behaviour.
        public static func pinchZoom(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? windowsPinchZoom : pinchZoom
        }

        public static func mirrorDrag(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? windowsMirrorDrag : mirrorDrag
        }

        public static func mirrorScroll(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? windowsMirrorScroll : mirrorScroll
        }

        /// SF Symbols has no Windows key and no Windows Task View, and the
        /// row's icon is decorative (`accessibilityHidden`), so this is
        /// about not drawing a Mac glyph next to PC wording.
        public static func modifierSymbol(for platform: IBModifierBar.PeerPlatform) -> String {
            platform == .windows ? "keyboard" : "command"
        }

        public static let windowsModifierBar = IBL("Lock Ctrl, Alt, ⊞ or Shift — they ride on every tap and gesture")
        public static let windowsThreeFingerSwipe = IBL("Three or four fingers up for Task View, sideways to switch virtual desktops")
        public static let windowsPinchZoom = IBL("Pinch to zoom the front app — it acts as Ctrl + scroll, so it zooms whatever the front app zooms")
        public static let windowsMirrorDrag = IBL("Keep one finger down and move to drag on your computer")
        public static let windowsMirrorScroll = IBL("Two fingers up or down to scroll your computer")

        // MARK: - App window mirror
        //
        // Its OWN section headings, not the trackpad's. Filing "two fingers
        // sideways to move the view" under a heading that says "Scroll &
        // zoom" hides the pan gesture from anyone who scans by heading —
        // and the mirror has no four-finger gesture, so it does not borrow
        // "Three & four fingers" for a single row.
        public static let mirrorSectionTap = IBL("Tap & drag")
        public static let mirrorSectionScroll = IBL("Scroll")
        public static let mirrorSectionMove = IBL("Move & zoom")
        public static let mirrorSectionThree = IBL("Three fingers")

        public static let mirrorTapClick = IBL("Tap a spot to click it there; double- or triple-tap for a double or triple click")
        public static let mirrorDrag = IBL("Keep one finger down and move to drag on the Mac")
        public static let mirrorRightClick = IBL("Press and hold, or two-finger tap, for right-click")

        /// Both one-liners because the axis lock is invisible: a reader who
        /// does not know a swipe can scroll or pan will try the obvious
        /// direction and be wrong about half the time.
        public static let mirrorScroll = IBL("Two fingers up or down to scroll the Mac")
        public static let mirrorPan = IBL("Two fingers sideways to move the view")
        public static let mirrorPinch = IBL("Pinch to zoom, keeping the point between your fingers in place")
        public static let mirrorDoubleTapZoom = IBL("Two-finger double-tap to zoom in on that spot; tap again to fit")
        public static let mirrorThreeFingerPan = IBL("Three fingers to move the view in both directions")

        public static let seeAll = IBL("See all gestures")

        public static let accessibilitySummary = IBL("Gestures: Touchpad — drag to move the cursor; tap to click, double- or triple-tap to repeat; two fingers scroll, tap for right-click, pinch to zoom the front app; hold or double-tap and hold to drag; three-finger tap for middle-click; three or four fingers to switch; lock Control, Option, Command and Shift to combine them, and Shift to select a range. App window mirror — tap to click, double- or triple-tap to repeat, hold to drag, press and hold or two-finger tap for right-click; two fingers up or down to scroll the Mac, sideways to move the view; pinch to zoom; two-finger double-tap to zoom in on a spot; three fingers to move the view freely.")
    }

    /// In-context trackpad hints: shown while the drag clutch is
    /// holding, and while ⇧ is locked on the modifier bar.
    public enum Trackpad {
        public static let clutchContinue = IBL("Dragging — lift to reposition your finger, touch down to continue")
        public static let shiftSelect = IBL("⇧ locked — tap the start, then tap the end, to select everything in between")
    }

    public enum Preview {
        public static let live = IBL("LIVE")
        public static func resolution(_ label: String) -> String { label }
        public static func frameRate(_ fps: Int) -> String { "\(fps) fps" }
        public static func bitrate(_ mbps: Int) -> String { "\(mbps) Mbps" }
        public static func latency(_ ms: Int) -> String { "\(ms) ms" }
        public static let codec = "H.264"
        public static let codecLabel = IBL("Codec")
        /// Mac window titles (title bar + Window menu).
        public static let windowTitle = IBL("RemoteCrab Preview")
        public static let controlPanelTitle = IBL("RemoteCrab Control Panel")
        /// VoiceOver label for the live video image.
        public static let a11yPreview = IBL("iPhone preview")
        /// Control-panel placeholder + actions.
        public static let noPreview = IBL("No preview")
        public static let title = IBL("Preview")
        public static let openHelp = IBL("Open the live preview window")
        /// Latency card eyebrow (rendered in caps).
        public static let latencyTitle = IBL("LATENCY")
        /// Preview-placeholder state messages (Mac).
        public static let searching = IBL("Looking for an iPhone on your WiFi…")
        public static func connectingTo(_ name: String) -> String {
            String(format: IBL("Connecting to %@…"), name)
        }
        public static func streamingFrom(_ name: String) -> String {
            String(format: IBL("Streaming from %@"), name)
        }
    }

    /// Optional virtual-microphone HAL driver.
    public enum MicDriver {
        public static let title = IBL("Microphone Driver")
        public static let installed = IBL("RemoteCrab Microphone is installed.")
        public static let notInstalled = IBL("Not installed — apps can't use the iPhone mic as a system input yet.")
        public static let install = IBL("Install Microphone Driver…")
        public static let remove = IBL("Remove")
        public static let footer = IBL("Installs a small System audio driver so Zoom, QuickTime, OBS and Dictation can pick “RemoteCrab Microphone”. Needs one admin authorization; audio briefly restarts.")
    }

    /// Mac setup assistant (first-run wizard). Replaces the old
    /// accessibility-only first-launch flow.
    public enum Setup {
        public static let title = IBL("Setup Assistant")
        /// Menu bar row shown while setup is incomplete.
        public static let finishSetup = IBL("Finish Setup…")
        public static let finishSetupHelp = IBL("Complete Accessibility and camera extension setup")
        /// Preferences button that brings the wizard back.
        public static let reopenWizard = IBL("Reopen Setup Assistant…")

        public static let stepWelcome = IBL("Welcome")
        public static let stepAccessibility = IBL("Accessibility")
        public static let stepScreenRecording = IBL("Screen Recording")
        public static let stepCamera = IBL("Virtual Camera")
        public static let stepMicrophone = IBL("Virtual Microphone")
        public static let stepDone = IBL("All Set")

        public static let welcomeBody = IBL("RemoteCrab turns your iPhone into a camera, microphone, trackpad and keyboard for this Mac. This short setup grants what macOS needs.")
        public static let welcomeHint = IBL("Also install RemoteCrab on your iPhone from the App Store — both devices must be on the same WiFi.")
        public static let begin = IBL("Begin Setup")

        public static let accessibilityWhy = IBL("RemoteCrab drives your Mac's cursor and keyboard from your iPhone — macOS requires the Accessibility permission for that. This step can't be skipped: without it, the trackpad and keyboard don't work.")
        public static let grantAccessibility = IBL("Grant Accessibility…")
        public static let accessibilitySteps = IBL("If no prompt appears, open System Settings → Privacy & Security → Accessibility and turn on RemoteCrab.")
        public static let restartToApply = IBL("Granted? Restart RemoteCrab")
        public static let restartHint = IBL("macOS caches this permission per running app — if you already turned it on but the status won't update, restart RemoteCrab once and it will be detected.")

        public static let cameraWhy = IBL("A small camera extension lets FaceTime, Zoom, Photo Booth and other apps select “RemoteCrab Camera”. macOS asks you to approve it once, then turn it on.")
        public static let cameraActivateSteps = IBL("Click “Enable Camera Extension” below — macOS will ask you to approve the extension once.")
        public static let cameraAwaiting = IBL("Waiting for approval — allow RemoteCrab in System Settings → Privacy & Security.")
        public static let cameraSteps = IBL("Open System Settings → General → Login Items & Extensions, then turn on RemoteCrab under Camera Extensions.")
        public static let cameraOptional = IBL("Optional — the trackpad and keyboard work without it.")

        public static let grantScreenRecording = IBL("Enable Screen Recording…")
        public static let screenRecordingOptional = IBL("Optional — needed only to mirror a Mac window to your iPhone.")

        public static let microphoneOptional = IBL("Optional — without it, iPhone audio only plays through your Mac's speakers.")
        public static let micPkgMissing = IBL("The installer package isn't bundled in this build. Build it with scripts/build-mic-driver-pkg.sh and embed it for distribution.")

        public static let skipForNow = IBL("Skip for now")
        public static let skipped = IBL("Skipped")
        public static let pending = IBL("Not yet")

        public static let doneBody = IBL("Open RemoteCrab from the menu bar and connect your iPhone to start.")
        public static let finish = IBL("Finish")
    }

    /// Offline demo mode (App Review can explore without a Mac).
    public enum Demo {
        public static let title = IBL("Demo Mode")
        public static let footer = IBL("Shows sample camera content so you can explore RemoteCrab without a computer. Live streaming, trackpad and keyboard need the computer receiver running.")
        public static let explainer = IBL("Demo Mode — sample content. No computer connected.")
        public static let badge = IBL("DEMO")
    }

    /// In-app ReplayKit recorder — lets the user capture the app's own screen
    /// on a physical device and send the clip to the computer.
    public enum Recorder {
        public static let title = IBL("Record a Demo Clip")
        public static let footer = IBL("Records this app's screen on your device. The clip is saved to Files or Photos, and you can send it to your computer from there. Recording stops if you leave the app.")
        public static let start = IBL("Start Recording")
        public static let stop = IBL("Stop Recording")
        public static let includeMicrophone = IBL("Include microphone audio")
        public static let unavailable = IBL("Screen recording is unavailable. Check Screen Recording restrictions in Settings.")
        public static let failed = IBL("Recording failed")
    }

    /// Keyboard surface strings.
    public enum Keyboard {
        public static let startTyping = IBL("Start typing…")
        /// Header + preview-card eyebrows (rendered in caps by design).
        public static let typingOnMac = IBL("TYPING ON MAC")
        public static let onYourMac = IBL("ON YOUR MAC")
        public static func charCount(_ count: Int) -> String {
            String(format: IBL("%lld chars"), count)
        }
    }

    /// iPhone-side Mac app switcher.
    public enum Switcher {
        public static let title = IBL("App Switcher")
        public static let desktop = IBL("Desktop")
        public static let showDesktop = IBL("Show Desktop")
        public static let launchApps = IBL("Open App…")
        public static let empty = IBL("No apps to switch to")
        public static let refresh = IBL("Refresh")
        public static let pin = IBL("Pin")
        public static let unpin = IBL("Unpin")
        public static let active = IBL("Active")
        public static let pinnedSection = IBL("Pinned")
        public static let allAppsSection = IBL("All Apps")
        public static let quit = IBL("Quit")
        public static let forceQuit = IBL("Force Quit")
        public static let forceQuitConfirmTitle = IBL("Force Quit App?")
        public static let forceQuitConfirmMessage = IBL("This immediately ends the app on the computer. Unsaved changes will be lost.")
        public static let permissionHint = IBL("Showing app icons — allow Screen Recording on the computer to see window previews.")
        public static func quitStillRunning(_ name: String) -> String {
            String(format: IBL("If “%@” is still open, it may be waiting for a save confirmation on the computer."), name)
        }
        public static let hint = IBL("Switch to a running app on the computer")
        public static let chordAppSwitcher = IBL("Switch apps")
        public static let chordCycleWindows = IBL("Cycle windows")
        public static let chordMissionControl = IBL("Mission Control")
        public static let chordAppExpose = IBL("App Exposé")
        public static let chordHideApp = IBL("Hide app")
        public static let chordQuitApp = IBL("Quit app")

        // MARK: - Windows chords
        //
        // The Windows row borrows the Mac *layout* but its keys do other
        // things, and these labels are what VoiceOver reads. Reusing the Mac
        // labels made Ctrl+Z announce as "Mission Control" and Ctrl+A as
        // "App Exposé" — correct text on the button, wrong action in the
        // ear. An accessibility label that names a different action than the
        // key performs is worse than no label, so each gets its own.

        /// Alt+Tab — switch windows.
        public static let windowsSwitchApps = IBL("Switch windows")
        /// Ctrl+W — close the current tab or window.
        public static let windowsCloseWindow = IBL("Close tab or window")
        /// Ctrl+Z — undo.
        public static let windowsUndo = IBL("Undo")
        /// Ctrl+A — select all.
        /// Reuses the catalog's existing "Select All" entry (zh: 全选) — adding a
        /// second key differing only in case collides in symbol generation.
        public static let windowsSelectAll = IBL("Select All")
        /// Alt+F4 — close the active window.
        public static let windowsCloseActive = IBL("Close window")
        /// Ctrl+Tab — next tab or window.
        public static let windowsNextTab = IBL("Next tab or window")
    }

    /// Frontmost-app context sheet (chip + sheet chrome; action labels
    /// stay English until the V1.2 localization batch).
    public enum Context {
        public static let open = IBL("App shortcuts")
        public static let systemSection = IBL("System")
        public static let footer = IBL("Buttons send keyboard or system events to your computer")
        /// The Mac wording above names the wrong computer on Windows.
        public static let footerWindows = IBL("Buttons send keyboard or system events to your computer")
        /// Shown under the suite title when it came from a file the user
        /// installed, so a button's origin is never invisible.
        public static let customSuite = IBL("Custom suite")
        // Context-sheet profile titles (frontmost Mac app → suite).
        public static let profilePresentation = IBL("Presentation")
        public static let profileAgent = IBL("Agent")
        public static let profileAI = IBL("AI")
        public static let profileOpenCode = IBL("OpenCode")
        public static let profileFinder = IBL("Finder")
        public static let profileNotes = IBL("Notes")
        public static let profileBrowser = IBL("Browser")
        public static let profileMail = IBL("Mail")
        public static let profileMessages = IBL("Messages")
        public static let profileCalendar = IBL("Calendar")
        public static let profileEditor = IBL("Editor")
        public static let profileConsole = IBL("Console")
        public static let profileXcode = IBL("Xcode")
        public static let profileText = IBL("Text")
        public static let profileMedia = IBL("Media")
        public static let profileChat = IBL("Chat")
        public static let profileMeeting = IBL("Meeting")
        public static let profileImage = IBL("Image")
        public static let profileNotebook = IBL("Notebook")
    }

    /// Recording the live stream to disk (Mac).
    public enum Record {
        public static let start = IBL("Start Recording")
        public static let stop = IBL("Stop Recording")
        public static let help = IBL("Record the live iPhone video and audio")
    }

    /// File transfer (iPhone → Mac).
    public enum Transfer {
        public static let sendTitle = IBL("Send to Computer")
        public static let photo = IBL("Photo or Video")
        public static let file = IBL("File")
        public static let sending = IBL("Sending…")
        public static let showInFinder = IBL("Show in Finder")
        public static let lastReceived = IBL("Last received file")
        public static let clipboardToMac = IBL("Send Clipboard to Computer")
        public static let clipboardToiPhone = IBL("Send Clipboard to iPhone")
        public static let clipboardHelp = IBL("Copy the computer's clipboard to the iPhone")
        public static let sendHint = IBL("Send a photo, video, or file to the computer")
        public static let latestScreenshot = IBL("Latest Screenshot")
        public static let noScreenshot = IBL("No screenshot found in your library.")
        public static let photosDenied = IBL("Photos access is off. Enable it in iOS Settings → Privacy → Photos, or pick a photo instead.")
    }

    /// Multi-computer pairing prompts and settings.
    ///
    /// Note the wording: the peer can be a Mac **or a Windows PC**, so the
    /// user-facing copy says "computer" wherever the two are interchangeable.
    /// "Mac" only survives where it is genuinely macOS-specific.
    public enum Pairing {
        public static let requestTitle = IBL("A computer wants to connect")
        public static func allowPrompt(_ name: String) -> String {
            String(format: IBL("Allow %@ to connect?"), name)
        }
        public static let allow = IBL("Allow")
        public static let deny = IBL("Deny")
        public static let pairedMacs = IBL("Paired computers")
        public static let connectedMac = IBL("Connected computer")
        public static let disconnect = IBL("Disconnect")
        public static let nonePaired = IBL("No computers paired yet. Pair one from its connection request.")
        public static let forget = IBL("Forget")
        // iOS computer picker (several computers on one network).
        public static let macPickerTitle = IBL("Choose a computer")
        public static let connectedNow = IBL("Connected")
        public static let waitingBadge = IBL("Preferred")
        /// Presence: the computer is announcing itself on the network right now.
        /// (Key differs from the value to avoid an Xcode symbol clash with the
        /// existing "OFFLINE" status-pill string.)
        public static let online = IBL("ComputerOnline")
        /// Presence: known from history but not announcing itself now.
        public static let offline = IBL("ComputerOffline")
        public static func waitingForPreferred(_ name: String) -> String {
            String(format: IBL("Waiting for %@ — if it doesn't reconnect on its own, click Retry in its menu."), name)
        }
        public static func waitingForCurrent(_ name: String) -> String {
            String(format: IBL("Waiting for %@…"), name)
        }
        public static let cancelPreferred = IBL("Cancel Preference")

        /// Why the chosen computer has not turned up yet.
        ///
        /// The headline above gives generic advice ("click Retry in its
        /// menu"), which is the right advice for exactly one of the four
        /// situations the phone can actually tell apart — and the phone
        /// *does* know which one it is, because it records the last outcome
        /// of every attempt. A `denied` computer will never retry on its own
        /// at all; a `busy` one retries every fifteen seconds and needs
        /// nothing. Telling those two apart is the difference between waiting
        /// and walking to another machine.
        public static func waitingReasonDenied(_ name: String) -> String {
            String(format: IBL("You denied %@ earlier, so it will only try again when you click Retry on that computer."), name)
        }
        public static func waitingReasonBusy(_ name: String) -> String {
            String(format: IBL("%@ is queuing politely — it retries on its own every 15 seconds."), name)
        }
        public static func waitingReasonApproval(_ name: String) -> String {
            String(format: IBL("%@ is waiting for you to Allow it on this phone."), name)
        }
        public static let waitingReasonNotSeenYet = IBL("It has not knocked at all yet — check that it is on this network and switched on.")
        /// Shown once when the grace period is spent. Without it the banner
        /// would simply vanish, which reads as a bug.
        public static func preferredGaveUp(_ name: String) -> String {
            String(format: IBL("Gave up waiting for %@ after 30 seconds. Any computer can connect again."), name)
        }
        /// The window itself, so "30 seconds" is never a surprise.
        public static let preferredGraceWindow = IBL("Holding the door for 30 seconds.")

        /// Shown on the surface the user is actually on, not only inside the
        /// picker. A switch that is invisible cannot be told apart from a
        /// switch that failed.
        public static func switchingTo(_ name: String) -> String {
            String(format: IBL("Switching to %@…"), name)
        }
        /// The action, because the state alone leaves the user guessing.
        public static let switchingHint = IBL("That computer connects on its own. If it doesn't, open this menu and pick it again — or disconnect the other one.")
        public static let pickerFooter = IBL("Several computers are on this network. Pick one — it takes over on its next connect; the others see \"in use\".")
        /// The last attempt's outcome, shown next to a computer in the picker.
        ///
        /// These three answers are what a user cannot work out for themselves:
        /// "streaming" says which machine is live, "waiting for approval" says
        /// the phone is holding a card they have not answered, and "in use" /
        /// "declined" say the computer *did* find us and was turned away — as
        /// opposed to never having found us at all, which is a network problem.
        public enum Attempt {
            public static let streaming = IBL("In use now")
            public static let waitingApproval = IBL("Waiting for your approval")
            public static let refusedBusy = IBL("Found you, but another computer is using the iPhone")
            public static let denied = IBL("You declined this computer")
            /// The absence of a knock is itself a diagnosis, so it gets words
            /// rather than a blank row: this machine has never reached this
            /// iPhone, which is a network problem and tapping the row will not
            /// fix it.
            public static let neverReached = IBL("Hasn't reached this iPhone yet — check the network")
            public static let refusedBusyShort = IBL("Turned away — iPhone in use")
            public static func refusedBusy(owner: String) -> String {
                String(format: IBL("Found this iPhone, but %@ is using it"), owner)
            }
            public static func lastSeen(_ text: String) -> String {
                String(format: IBL("Last tried %@"), text)
            }
        }
        /// Section header for computers seen on the network, paired or not.
        public static let seenComputers = IBL("On this network")
        /// Badge for a computer that has never been paired (first contact).
        public static let notPairedBadge = IBL("New")
        public static let currentComputer = IBL("This iPhone")
        public static let releaseCurrent = IBL("Release this iPhone")
        public static let releaseCurrentHint = IBL("Let the next computer that connects become the one this iPhone serves.")
        /// Per-row delete confirmation. A paired computer can otherwise be
        /// removed with a single stray swipe, and getting it back means
        /// approving it again from scratch — so the sentence says that.
        public static func confirmForget(_ name: String) -> String {
            String(format: IBL("Forget %@? It will need approval again to reconnect."), name)
        }
    }

    public enum Error {
        public static let noCameraPermission = IBL("Camera permission denied. Enable in iOS Settings → Privacy → Camera.")
        public static let noMicPermission = IBL("Microphone permission denied. Enable in iOS Settings → Privacy → Microphone.")
        public static let noLocalNetwork = IBL("Local network permission denied. Enable in iOS Settings → Privacy → Local Network.")
        public static let searchingHint = IBL("Make sure the desktop app is running, both are on the same WiFi, and keep this app in the foreground.")
        /// Title of the idle/waiting card: the iPhone is the TCP server,
        /// so it can only WAIT for a Mac — "connecting" misleads.
        public static let waitingForMac = IBL("Waiting for your computer")
        /// Waiting-card subtitle once the WiFi address is known: gives
        /// the user the manual-connect escape hatch when Bonjour is
        /// blocked (VPN, client isolation, hotspot).
        public static func manualConnectHint(_ address: String) -> String {
            String(format: IBL("On the Mac: menu bar → RemoteCrab → Connect by IP → %@"), address)
        }
        public static let resumedAfterBackground = IBL("Video stopped in the background — tap the camera icon to turn it back on.")
        public static let noMacFound = IBL("No computer found on the WiFi network. Make sure RemoteCrab Receiver is running.")
        public static let bonjourFailed = IBL("Bonjour discovery failed. Check that both devices are on the same WiFi.")
        public static let connectionLost = IBL("Connection to the computer lost. Reconnecting…")
        /// Mac-side counterpart of `connectionLost` (the peer that went
        /// away from the receiver's perspective is the iPhone).
        public static let iPhoneConnectionLost = IBL("Connection to your iPhone was lost. Waiting for it to reconnect…")
        public static let streamingFailed = IBL("Streaming failed. Tap to retry.")
        /// Raised when the user asks for something the receiver has to do
        /// (switch app, quit it, launch one) while there is no live link to
        /// ask over. Without it the tap was acknowledged by a haptic and
        /// then nothing ever happened, with the UI still claiming to be
        /// connected.
        public static let notConnectedToMac = IBL("Not connected to your computer right now.")
        /// Raised once when the measured round trip settles into "poor" and
        /// retracted when it recovers — see `CaptureEngine.updateLatencyHint`.
        public static let slowConnection = IBL("The connection to your computer is slow. Video and input may lag.")
        /// A failure that is not about the Mac at all — the old single
        /// "Connection to Mac lost" sentence sent users looking at Wi-Fi
        /// while the camera was the problem.
        public static let captureStartFailed = IBL("The camera could not start. Close any other app using it, then try again.")
        /// On iOS a listener that will not start is almost always the
        /// local-network permission, so say that instead of "reconnecting".
        public static let networkUnavailable = IBL("RemoteCrab could not reach the local network. Check that Wi-Fi is on and this app may use it in Settings.")

        // Multi-Mac pairing.
        /// The state, AND the action.
        ///
        /// It used to say only "already in use by X" — which left the user
        /// with one button, **Retry**, that cannot ever succeed while
        /// another computer holds the phone. So the honest next step was
        /// discoverable nowhere: you have to go to the iPhone and use
        /// Choose a Computer, and no surface said so. This is the rule in
        /// AGENTS.md ("the line that states what is happening must also
        /// state what to do") applied to the one row that lacked it.
        public static func iphoneBusy(_ owner: String) -> String {
            String(format: IBL("This iPhone is being used by %@ — pick this computer in the iPhone's Choose a Computer list. Retry on its own will keep failing."), owner)
        }
        public static let iphoneBusyUnknown = IBL("This iPhone is already in use by another computer")
        public static let connectionDenied = IBL("The iPhone denied the connection")
        /// The phone's user tapped Disconnect. Says what happened AND what to do
        /// (AGENTS rule 1): pick this computer again on the phone.
        public static let connectionOff = IBL("Disconnected on the iPhone — open Choose a Computer there and pick this one to reconnect.")
        public static let awaitingApproval = IBL("Waiting for approval on the iPhone…")
        /// The idle wait once the receiver has learned the phone dials itself:
        /// there is nothing for this Mac to do, so the line names the action on
        /// the phone instead of the legacy "looking for an iPhone".
        public static let waitingForPhone = IBL("Open RemoteCrab on your iPhone and pick this computer.")
        public static let retry = IBL("Retry")
        /// The receiver verified that the machine on this address holds the
        /// pairing token, but the phone could not prove the same to us, or
        /// proved the wrong thing. Distinct from a lost connection and from a
        /// human refusal: it is an identity failure, so it says so and stops.
        public static let cannotVerifyiPhone = IBL("Could not verify the iPhone's identity — someone may be impersonating it. Stopped reconnecting.")
        /// Appended to the connected row when the session could not be
        /// authenticated (an older phone that does not do the exchange). Honest
        /// about the gap rather than pretending the link is verified.
        public static let sessionUnverified = IBL("Unverified identity")
    }

    /// Why a command the user tapped on the phone did not visibly happen.
    /// Each cause gets its own sentence: they used to be indistinguishable
    /// from the phone, which is the whole reason `commandResult` exists.
    public enum Command {
        /// The receiver never answered, so it is too old to know the request
        /// id. Wording matters — it is a capability gap, not a failure.
        public static let unconfirmed = IBL("Couldn't confirm with your computer — its app may be out of date.")
        public static let noPermission = IBL("Your Mac needs Accessibility permission to control apps.")
        public static let noWindow = IBL("That window isn't open on your computer anymore.")
        public static let refused = IBL("Your computer refused that request.")
        public static func appNotRunning(_ name: String) -> String {
            String(format: IBL("“%@” is no longer running."), name)
        }
    }

    /// Accessibility (VoiceOver) labels and hints. These are heard, not
    /// seen, so they live apart from the visible-copy enums — every
    /// `.accessibilityLabel` / `.accessibilityHint` in both apps must
    /// come from here (or from an existing IBLocale value) rather than
    /// a hardcoded literal, so Chinese users hear Chinese.
    public enum A11y {
        // Generic on/off state values for toggles and lockable keys.
        public static let on = IBL("On")
        public static let off = IBL("Off")

        // Generic dismiss affordance (sheet close buttons).
        public static let close = IBL("Close")

        // iOS feature dock.
        public static let microphone = IBL("Microphone")
        /// One control, three states. Named "Audio mode" rather than
        /// "Microphone" so a screen-reader user is not told the control does
        /// something it does not.
        public static let audioMode = IBL("Audio mode")
        public static let audioModeHint = IBL("Choose whether this phone's microphone streams to the computer, or the computer's sound plays out of this phone, or both are off")
        public static func showsSurface(_ name: String) -> String {
            String(format: IBL("Shows the %@ surface"), name)
        }
        public static let voiceReleaseToStop = IBL("Voice. Release to stop.")
        public static let voiceHoldToTalk = IBL("Voice. Hold to talk.")
        public static let voiceToggle = IBL("Toggle Voice Input")

        // Touch surfaces (full-screen trackpad + keyboard mini trackpad).
        public static let trackpadSurface = IBL("Trackpad surface")
        public static let trackpadSurfaceHint = IBL("Touch directly to move the computer cursor")
        public static let miniTrackpad = IBL("Mini trackpad")

        // iOS camera surface + PiP.
        public static let switchCamera = IBL("Switch camera")
        public static let switchCameraHint = IBL("Flips between the front and back cameras")
        public static let cameraPreview = IBL("Camera preview")
        public static let pipHint = IBL("Tap to show the camera full screen, drag to move")
        public static let closeCamera = IBL("Close camera view")

        // iOS hold-to-talk voice card.
        public static let voiceInputError = IBL("Voice input error")
        public static let dictationSent = IBL("Dictation sent")
        public static let voiceInput = IBL("Voice input")

        // Connection status pill — read on every surface (iOS top bar,
        // Mac popover, control panel, preview, test window).
        public static func statusPlain(_ label: String) -> String {
            String(format: IBL("Connection: %@"), label)
        }
        public static func statusConnectedLatency(_ label: String, _ ms: Int) -> String {
            String(format: IBL("Connection: %@, latency %d ms"), label, ms)
        }
        public static func statusDisconnected(_ label: String, _ reason: String) -> String {
            String(format: IBL("Connection: %@. %@"), label, reason)
        }

        // iOS keyboard shortcut bar + modifier keys (shared with
        // `IBModifierBar` in RemoteCrabCore).
        public static let escapeKey = IBL("Escape key")
        public static let tabKey = IBL("Tab key")
        public static let deleteKey = IBL("Delete key")
        public static let commaKey = IBL("Comma key")
        public static let periodKey = IBL("Period key")
        public static let returnKey = IBL("Return key")
        public static let leftArrowKey = IBL("Left arrow key")
        public static let rightArrowKey = IBL("Right arrow key")
        public static let controlKey = IBL("Control key")
        public static let optionKey = IBL("Option key")
        public static let commandKey = IBL("Command key")
        public static let shiftKey = IBL("Shift key")
        /// ⊞ on a Windows peer. Deliberately not "Windows key key".
        public static let windowsKey = IBL("Windows key")

        // Trackpad labs floating buttons.
        public static let holdToActivate = IBL("Hold to activate")

        // iOS settings.
        public static let frameRate = IBL("Frame rate")
        public static let trackpadSensitivity = IBL("Trackpad sensitivity")
        public static let streamMicHint = IBL("Stream the iPhone microphone to your computer")
        public static let keepScreenOnHint = IBL("Prevents the iPhone from auto-locking during a streaming session")
        public static let airMouseHint = IBL("Hold the floating button on the trackpad and tilt your iPhone to move the cursor")
        public static let wheelScrollHint = IBL("Hold the edge button on the trackpad and draw circles to scroll")
        public static let privacyPolicySafari = IBL("Privacy Policy (opens in Safari)")

        // Mac preferences pickers.
        public static let cameraPosition = IBL("Camera position")
        public static let cameraPositionHint = IBL("Which iPhone camera to use as the live feed")
        public static let streamingResolution = IBL("Streaming resolution")
        public static let streamingResolutionHint = IBL("Higher resolutions use more WiFi bandwidth")
        public static let streamingFrameRate = IBL("Streaming frame rate")
        public static let micAudioQuality = IBL("Microphone audio quality")

        // Mac chrome: menu bar extra, control panel, test window.
        public static let recording = IBL("Recording")
        public static let connectionTest = IBL("Connection Test")
        public static let speakerMonitoring = IBL("Speaker monitoring")

        // Mac test-window live camera image.
        public static let liveCamera = IBL("Live camera")
    }

    /// Mac menu-bar popover: section headers, feature-toggle subtitles,
    /// and action rows.
    public enum MenuBar {
        public static let featuresSection = IBL("FEATURES")
        public static let actionsSection = IBL("ACTIONS")

        public static let cameraSubtitle = IBL("Live iPhone feed")
        public static let micSubtitle = IBL("Stream iPhone mic")
        public static let trackpadSubtitle = IBL("Control computer cursor")
        public static let keyboardSubtitle = IBL("Type on the computer")

        public static let openControlPanel = IBL("Open Control Panel")
        public static let openControlPanelHelp = IBL("Show the floating control panel")
        public static let openPreviewWindow = IBL("Open Preview Window")
        public static let openPreviewWindowHelp = IBL("Show the live camera preview window")
        public static let connectionTestHelp = IBL("Verify camera, keyboard, trackpad and mic live")
        public static let preferences = IBL("Preferences…")
        public static let preferencesHelp = IBL("Open RemoteCrab settings")
    }

    /// Mac connection-test window (four-quadrant live verification).
    public enum TestWindow {
        public static let subtitle = IBL("LIVE INPUT VERIFICATION")
        public static let noVideo = IBL("No video")
        public static let keyboardPlaceholder = IBL("Type on your iPhone keyboard…")
        public static let noKeysYet = IBL("NO KEYS YET")
        public static let trackpadPlaceholder = IBL("Slide on the iPhone trackpad…")
        public static let monitoringOffHelp = IBL("Speaker monitoring off — tap to hear the iPhone mic")
        public static let monitoringOnHelp = IBL("Speaker monitoring on — tap to mute (avoids echo)")
    }
}
