import Foundation

/// One button in the context sheet. `.key` replays a Mac keyboard
/// event (existing KeyEvent injection); `.system` is an
/// IBSystemCommand (Task 1); `.voiceHero` is the push-to-talk
/// shortcut handled by the sheet itself.
public enum ContextAction: Equatable, Sendable {
    case key(label: String, symbol: String, keycode: UInt16, modifiers: UInt8 = 0)
    case system(label: String, symbol: String, command: IBSystemCommand.Command)
    case voiceHero(label: String, symbol: String)
}

/// A frontmost-app-keyed set of shortcuts. Pure data — rendering
/// lives in the iOS ContextSheetView.
public struct ContextProfile: Equatable, Sendable {
    public let id: String
    /// IBLocale key suffix (Context.<titleKey>).
    public let titleKey: String
    public let actions: [ContextAction]
    public init(id: String, titleKey: String, actions: [ContextAction]) {
        self.id = id
        self.titleKey = titleKey
        self.actions = actions
    }
}

/// Registry: frontmost Mac app (from IBAppList / isActive) → profile.
/// Terminals map to the agent suite — iOS cannot see which process
/// runs inside the terminal, that is the documented V1.1 heuristic.
public enum ContextProfiles {

    private static let presentationBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
    ]

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    public static func profile(for app: IBAppInfo?) -> ContextProfile {
        guard let app else { return console }
        if presentationBundleIDs.contains(app.id) { return presentation }
        if terminalBundleIDs.contains(app.id) { return agent }
        return console
    }

    // Keycodes: ← 123, → 124, B 11, W 13, ESC 53, ⏎ 36, C 8, V 9, Q 12.
    // Modifier mask: shift=1, control=2, option=4, command=8.

    public static let presentation = ContextProfile(id: "presentation", titleKey: "presentation", actions: [
        .key(label: "Play / Exit", symbol: "play.fill", keycode: 35, modifiers: 4 | 8),   // ⌥⌘P
        .key(label: "Previous", symbol: "chevron.left", keycode: 123),
        .key(label: "Next", symbol: "chevron.right", keycode: 124),
        .key(label: "Black Screen", symbol: "rectangle.fill", keycode: 11),               // B
        .key(label: "White Screen", symbol: "rectangle", keycode: 13),                    // W
        .key(label: "Exit", symbol: "escape", keycode: 53),
    ])

    public static let agent = ContextProfile(id: "agent", titleKey: "agent", actions: [
        .voiceHero(label: "Talk to Agent", symbol: "waveform"),
        .key(label: "Approve", symbol: "checkmark", keycode: 36),                          // ⏎
        .key(label: "Interrupt", symbol: "xmark", keycode: 8, modifiers: 2),               // ⌃C
        .key(label: "Copy", symbol: "doc.on.doc", keycode: 8, modifiers: 8),               // ⌘C
        .key(label: "Paste", symbol: "doc.on.clipboard", keycode: 9, modifiers: 8),        // ⌘V
        .key(label: "Escape", symbol: "escape", keycode: 53),
    ])

    public static let console = ContextProfile(id: "console", titleKey: "console", actions: [
        .system(label: "Volume +", symbol: "speaker.plus.fill", command: .volumeUp),
        .system(label: "Volume −", symbol: "speaker.minus.fill", command: .volumeDown),
        .system(label: "Mute", symbol: "speaker.slash.fill", command: .volumeMute),
        .system(label: "Brightness +", symbol: "sun.max.fill", command: .brightnessUp),
        .system(label: "Brightness −", symbol: "sun.min.fill", command: .brightnessDown),
        .system(label: "Play / Pause", symbol: "playpause.fill", command: .mediaPlayPause),
        .key(label: "Lock Screen", symbol: "lock.fill", keycode: 12, modifiers: 2 | 8),    // ⌃⌘Q
        .system(label: "Safari", symbol: "safari.fill", command: .launchApp),
    ])
}
