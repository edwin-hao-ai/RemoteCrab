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
    public enum App {
        public static let name = IBL("RemoteCrab")
        public static let tagline = IBL("Mac receiver")
        public static let captureName = IBL("RemoteCrab")
        public static let receiverName = IBL("RemoteCrab Receiver")
        /// Overflow-menu button label.
        public static let more = IBL("More")
        public static let quit = IBL("Quit RemoteCrab")
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
        public static let cameraReason = IBL("RemoteCrab turns your iPhone's camera into a high-quality webcam for your Mac. We use it in real time — nothing is recorded or uploaded.")

        public static let microphone = IBL("Microphone Access")
        public static let microphoneReason = IBL("RemoteCrab can stream your iPhone's microphone to your Mac. This is optional — toggle it off in the camera screen anytime.")

        public static let localNetwork = IBL("Local Network Access")
        public static let localNetworkReason = IBL("RemoteCrab uses Bonjour to find your Mac on the same WiFi. Without this, the two devices can't talk to each other.")

        public static let speech = IBL("Speech Recognition")
        public static let speechReason = IBL("Hold the voice button to dictate text into your Mac. Recognition happens on your iPhone — audio never leaves your device for this feature.")

        public static let accessibility = IBL("Accessibility Permission")
        public static let accessibilityReason = IBL("We need Accessibility to drive your Mac's cursor and keyboard from your iPhone.")

        public static let allow = IBL("Allow")
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
    }

    public enum Onboarding {
        public static let heroTitle = IBL("RemoteCrab")
        public static let heroBody = IBL("Turn your iPhone into a camera, microphone, trackpad and keyboard for your Mac — over WiFi.")
        public static let permissionsTitle = IBL("We need a few permissions")
        public static let permissionsBody = IBL("RemoteCrab needs to use your camera, microphone, and local network. We only ever send data to your Mac — nothing leaves your WiFi.")
        public static let pairTitle = IBL("Connect to your Mac")
        public static let pairBody = IBL("Download and open RemoteCrab Receiver on your Mac, then tap Allow Permissions & Connect. They'll find each other automatically.")
        public static let getStarted = IBL("Get Started")
        public static let skip = IBL("Skip")
        public static let nextBtn = IBL("Continue")
        public static let allowAndConnect = IBL("Allow Permissions & Connect")
        /// Pair-page illustration: both devices must share a network.
        public static let sameWiFi = IBL("Same WiFi")
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
    }

    /// Hold-to-talk voice card states.
    public enum Voice {
        public static let listening = IBL("Listening…")
        public static let sent = IBL("Sent")
        public static let holdToTalk = IBL("Hold to talk")
        public static let releaseToSend = IBL("Release to send")
    }

    /// Settings → Labs (experimental gestures, default off).
    public enum Labs {
        public static let title = IBL("Labs")
        public static let airMouse = IBL("Air mouse")
        public static let wheelScroll = IBL("Wheel scrolling")
        public static let footer = IBL("Experimental gestures. Air mouse: hold the floating button on the trackpad and tilt your iPhone to move the cursor. Wheel scrolling: hold the edge button and draw circles to scroll.")
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
        public static let dragMove = IBL("Drag to move the cursor")
        public static let doubleTapHoldDrag = IBL("Hold still, or double-tap and hold, to drag")
        public static let twoFingerScrollRightClick = IBL("Two fingers to scroll or right-click")
        public static let accessibilitySummary = IBL("Trackpad gestures: drag to move the cursor, double-tap and hold to drag, two fingers to scroll or right-click")
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
        public static let footer = IBL("Shows sample camera content so you can explore RemoteCrab without a Mac. Live streaming, trackpad and keyboard need the Mac receiver running.")
        public static let explainer = IBL("Demo Mode — sample content. No Mac connected.")
        public static let badge = IBL("DEMO")
    }

    /// Keyboard surface strings.
    public enum Keyboard {
        public static let startTyping = IBL("Start typing…")
    }

    /// iPhone-side Mac app switcher.
    public enum Switcher {
        public static let title = IBL("App Switcher")
        public static let empty = IBL("No apps to switch to")
        public static let refresh = IBL("Refresh")
        public static let pin = IBL("Pin")
        public static let unpin = IBL("Unpin")
        public static let active = IBL("Active")
        public static let hint = IBL("Switch to a running app on the Mac")
        public static let chordAppSwitcher = IBL("Switch apps")
        public static let chordCycleWindows = IBL("Cycle windows")
        public static let chordMissionControl = IBL("Mission Control")
        public static let chordAppExpose = IBL("App Exposé")
        public static let chordHideApp = IBL("Hide app")
        public static let chordQuitApp = IBL("Quit app")
    }

    /// Recording the live stream to disk (Mac).
    public enum Record {
        public static let start = IBL("Start Recording")
        public static let stop = IBL("Stop Recording")
        public static let help = IBL("Record the live iPhone video and audio")
    }

    /// File transfer (iPhone → Mac).
    public enum Transfer {
        public static let sendTitle = IBL("Send to Mac")
        public static let photo = IBL("Photo or Video")
        public static let file = IBL("File")
        public static let sending = IBL("Sending…")
        public static let showInFinder = IBL("Show in Finder")
        public static let lastReceived = IBL("Last received file")
        public static let clipboardToMac = IBL("Send Clipboard to Mac")
        public static let clipboardToiPhone = IBL("Send Clipboard to iPhone")
        public static let clipboardHelp = IBL("Copy the Mac clipboard to the iPhone")
        public static let sendHint = IBL("Send a photo, video, or file to the Mac")
    }

    /// Multi-Mac pairing prompts and settings.
    public enum Pairing {
        public static let requestTitle = IBL("A Mac wants to connect")
        public static func allowPrompt(_ name: String) -> String {
            String(format: IBL("Allow %@ to connect?"), name)
        }
        public static let allow = IBL("Allow")
        public static let deny = IBL("Deny")
        public static let pairedMacs = IBL("Paired Macs")
        public static let connectedMac = IBL("Connected Mac")
        public static let disconnect = IBL("Disconnect")
        public static let nonePaired = IBL("No Macs paired yet. Pair one from its connection request.")
        public static let forget = IBL("Forget")
        // iOS Mac picker (several Macs on one network).
        public static let macPickerTitle = IBL("Choose a Mac")
        public static let connectedNow = IBL("Connected")
        public static let waitingBadge = IBL("Preferred")
        public static func waitingForPreferred(_ name: String) -> String {
            String(format: IBL("Waiting for %@ — if it doesn't reconnect on its own, click Retry in its menu bar."), name)
        }
        public static let cancelPreferred = IBL("Cancel Preference")
        public static let pickerFooter = IBL("Several Macs are on this network. Pick one — it takes over on its next connect; others see \"busy\".")
    }

    public enum Error {
        public static let noCameraPermission = IBL("Camera permission denied. Enable in iOS Settings → Privacy → Camera.")
        public static let noMicPermission = IBL("Microphone permission denied. Enable in iOS Settings → Privacy → Microphone.")
        public static let noLocalNetwork = IBL("Local network permission denied. Enable in iOS Settings → Privacy → Local Network.")
        public static let searchingHint = IBL("Looking for your Mac on the same WiFi…")
        /// Title of the idle/waiting card: the iPhone is the TCP server,
        /// so it can only WAIT for a Mac — "connecting" misleads.
        public static let waitingForMac = IBL("Waiting for your Mac")
        /// Waiting-card subtitle once the WiFi address is known: gives
        /// the user the manual-connect escape hatch when Bonjour is
        /// blocked (VPN, client isolation, hotspot).
        public static func manualConnectHint(_ address: String) -> String {
            String(format: IBL("On the Mac: menu bar → RemoteCrab → Connect by IP → %@"), address)
        }
        public static let resumedAfterBackground = IBL("Video stopped in the background — tap the camera icon to turn it back on.")
        public static let noMacFound = IBL("No Mac found on the WiFi network. Make sure RemoteCrab Receiver is running.")
        public static let bonjourFailed = IBL("Bonjour discovery failed. Check that both devices are on the same WiFi.")
        public static let connectionLost = IBL("Connection to Mac lost. Reconnecting…")
        /// Mac-side counterpart of `connectionLost` (the peer that went
        /// away from the receiver's perspective is the iPhone).
        public static let iPhoneConnectionLost = IBL("Connection to your iPhone was lost. Waiting for it to reconnect…")
        public static let streamingFailed = IBL("Streaming failed. Tap to retry.")

        // Multi-Mac pairing.
        public static func iphoneBusy(_ owner: String) -> String {
            String(format: IBL("This iPhone is already in use by %@"), owner)
        }
        public static let iphoneBusyUnknown = IBL("This iPhone is already in use by another Mac")
        public static let connectionDenied = IBL("The iPhone denied the connection")
        public static let awaitingApproval = IBL("Waiting for approval on the iPhone…")
        public static let retry = IBL("Retry")
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

        // iOS feature dock.
        public static let microphone = IBL("Microphone")
        public static func showsSurface(_ name: String) -> String {
            String(format: IBL("Shows the %@ surface"), name)
        }
        public static let voiceReleaseToStop = IBL("Voice. Release to stop.")
        public static let voiceHoldToTalk = IBL("Voice. Hold to talk.")
        public static let voiceToggle = IBL("Toggle Voice Input")

        // Touch surfaces (full-screen trackpad + keyboard mini trackpad).
        public static let trackpadSurface = IBL("Trackpad surface")
        public static let trackpadSurfaceHint = IBL("Touch directly to move the Mac cursor")
        public static let miniTrackpad = IBL("Mini trackpad")

        // iOS camera surface + PiP.
        public static let switchCamera = IBL("Switch camera")
        public static let switchCameraHint = IBL("Flips between the front and back cameras")
        public static let cameraPreview = IBL("Camera preview")
        public static let pipHint = IBL("Tap to show the camera full screen, drag to move")

        // iOS hold-to-talk voice card.
        public static let voiceInputError = IBL("Voice input error")
        public static let dictationSent = IBL("Dictation sent")
        public static let voiceInput = IBL("Voice input")

        // iOS keyboard shortcut bar + modifier keys (shared with
        // `IBModifierBar` in RemoteCrabCore).
        public static let escapeKey = IBL("Escape key")
        public static let tabKey = IBL("Tab key")
        public static let leftArrowKey = IBL("Left arrow key")
        public static let rightArrowKey = IBL("Right arrow key")
        public static let controlKey = IBL("Control key")
        public static let optionKey = IBL("Option key")
        public static let commandKey = IBL("Command key")
        public static let shiftKey = IBL("Shift key")

        // Trackpad labs floating buttons.
        public static let holdToActivate = IBL("Hold to activate")

        // iOS settings.
        public static let frameRate = IBL("Frame rate")
        public static let trackpadSensitivity = IBL("Trackpad sensitivity")
        public static let streamMicHint = IBL("Stream the iPhone microphone to your Mac")
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
    }
}
