import Foundation

/// Centralized user-facing strings for iBridge.
///
/// All UI text in both apps (iOS Capture + Mac Receiver) should pull
/// from here. To localize: replace the English values with
/// `NSLocalizedString` calls and ship per-language `Localizable.strings`
/// in the resource bundle. The current setup keeps the strings inline
/// (single language, English) for V0.2 — the per-app `Info.plist`
/// already declares the languages we ship in `project-*.yml`.
///
/// Adding a new language is a one-line change: e.g. add `let cancelJa = "キャンセル"`.
public enum IBLocale {
    public enum App {
        public static let name = "iBridge"
        public static let tagline = "Mac receiver"
        public static let captureName = "iBridge Capture"
    }

    public enum Status {
        public static let looking = "LOOKING"
        public static let connecting = "CONNECTING"
        public static let live = "LIVE"
        public static let offline = "OFFLINE"
        public static let reconnecting = "RECONNECTING"

        public static func latency(_ ms: Int) -> String { "\(ms) ms" }
    }

    public enum Permission {
        public static let camera = "Camera Access"
        public static let cameraReason = "iBridge turns your iPhone's camera into a high-quality webcam for your Mac. We use it in real time — nothing is recorded or uploaded."

        public static let microphone = "Microphone Access"
        public static let microphoneReason = "iBridge can stream your iPhone's microphone to your Mac. This is optional — toggle it off in the camera screen anytime."

        public static let localNetwork = "Local Network Access"
        public static let localNetworkReason = "iBridge uses Bonjour to find your Mac on the same WiFi. Without this, the two devices can't talk to each other."

        public static let accessibility = "Accessibility Permission"
        public static let accessibilityReason = "We need Accessibility to drive your Mac's cursor and keyboard from your iPhone."

        public static let allow = "Allow"
        public static let notNow = "Not now"
        public static let granted = "Granted"
        public static let denied = "Denied — you can enable this later in Settings"
        public static let openSystemSettings = "Open System Settings"
        public static let recheck = "Re-check"
        public static let accessibilityRequired = "Accessibility permission required"
        public static let accessibilityGranted = "Accessibility granted"
    }

    public enum Onboarding {
        public static let heroTitle = "iBridge"
        public static let heroBody = "Turn your iPhone into a camera, microphone, trackpad and keyboard for your Mac — over WiFi."
        public static let permissionsTitle = "We need a few permissions"
        public static let permissionsBody = "iBridge needs to use your camera, microphone, and local network. We only ever send data to your Mac — nothing leaves your WiFi."
        public static let pairTitle = "Connect to your Mac"
        public static let pairBody = "Download and open iBridge Receiver on your Mac, then tap Allow Permissions & Connect. They'll find each other automatically."
        public static let getStarted = "Get Started"
        public static let skip = "Skip"
        public static let nextBtn = "Continue"
        public static let allowAndConnect = "Allow Permissions & Connect"
    }

    public enum Mode {
        public static let camera = "Camera"
        public static let trackpad = "Trackpad"
        public static let keyboard = "Keyboard"
        public static let touchpad = "Touchpad"  // alias

        public static func label(_ mode: String) -> String { mode }
    }

    public enum Mic {
        public static let on = "Mic on"
        public static let off = "Mic off"
    }

    public enum Settings {
        public static let title = "Settings"
        public static let general = "General"
        public static let streaming = "Streaming"
        public static let video = "Video"
        public static let audio = "Audio"
        public static let network = "Network"
        public static let about = "About"
        public static let accessibility = "Accessibility"
        public static let permissions = "Permissions"

        public enum Resolution: String, CaseIterable, Identifiable {
            case p720  = "720p"
            case p1080 = "1080p"
            case p1440 = "1440p"
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
            on ? "Open iBridge at login" : "Don't open at login"
        }
        public static let launchAtLoginDescription = "Start iBridge Receiver automatically when you log in."

        public static let versionLabel = "Version"
        public static let buildLabel = "Build"
        public static let builtFor = "Built for"
        public static let copyrightLabel = "© iBridge. Local-first, no cloud, no analytics."

        public static let resetAccessibility = "Re-request Accessibility permission"
        public static let openAtLogin = "Open at Login"
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
        public static let drag = "Drag"
        public static let dragDescription = "Move cursor"
        public static let tap = "Tap"
        public static let tapDescription = "Left click"
        public static let twoFinger = "Two fingers"
        public static let twoFingerDescription = "Scroll / right click"
    }

    public enum Preview {
        public static let live = "LIVE"
        public static func resolution(_ label: String) -> String { label }
        public static func frameRate(_ fps: Int) -> String { "\(fps) fps" }
        public static func bitrate(_ mbps: Int) -> String { "\(mbps) Mbps" }
        public static func latency(_ ms: Int) -> String { "\(ms) ms" }
        public static let codec = "H.264"
        public static let codecLabel = "Codec"
    }

    public enum Error {
        public static let noCameraPermission = "Camera permission denied. Enable in iOS Settings → Privacy → Camera."
        public static let noMicPermission = "Microphone permission denied. Enable in iOS Settings → Privacy → Microphone."
        public static let noLocalNetwork = "Local network permission denied. Enable in iOS Settings → Privacy → Local Network."
        public static let noMacFound = "No Mac found on the WiFi network. Make sure iBridge Receiver is running."
        public static let bonjourFailed = "Bonjour discovery failed. Check that both devices are on the same WiFi."
        public static let connectionLost = "Connection to Mac lost. Reconnecting…"
        public static let streamingFailed = "Streaming failed. Tap to retry."
    }
}