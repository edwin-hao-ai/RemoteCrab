import Foundation

/// One button in the context sheet. `.key` replays a Mac keyboard
/// event (existing KeyEvent injection); `.system` is an
/// IBSystemCommand; `.voiceHero` is the push-to-talk shortcut handled
/// by the sheet itself.
///
/// `Codable` on purpose: the profile registry is designed to grow into
/// a plugin marketplace where developers ship their own suites as
/// JSON, so the action model must round-trip through a file. Nothing
/// remote is loaded yet — this is the forward-compatible shape only.
public enum ContextAction: Codable, Equatable, Sendable {
    case key(label: String, symbol: String, keycode: UInt16, modifiers: UInt8 = 0)
    case system(label: String, symbol: String, command: IBSystemCommand.Command)
    case voiceHero(label: String, symbol: String)
}

/// A frontmost-app-keyed set of shortcuts.
///
/// Pure, `Codable` data — rendering lives in the iOS
/// `ContextSheetView`. `bundleIDs` makes each profile self-describing
/// (which Mac apps it claims), which is what a marketplace entry needs;
/// the registry below is just the built-in set.
public struct ContextProfile: Codable, Equatable, Sendable {
    public let id: String
    /// Display name shown in the sheet header (localized for built-ins).
    public let title: String
    /// Mac bundle identifiers this profile matches, first-match-wins.
    public let bundleIDs: [String]
    public let actions: [ContextAction]

    public init(id: String, title: String, bundleIDs: [String] = [], actions: [ContextAction]) {
        self.id = id
        self.title = title
        self.bundleIDs = bundleIDs
        self.actions = actions
    }

    /// The push-to-talk hero, if this profile has one. Rendered
    /// full-width above the grid (a two-column grid would clip it).
    public var voiceHero: ContextAction? {
        actions.first { if case .voiceHero = $0 { return true }; return false }
    }

    /// Everything except the voice hero — the actions laid out in the
    /// two-column grid. Related controls must be adjacent (same row).
    public var gridActions: [ContextAction] {
        actions.filter { if case .voiceHero = $0 { return false }; return true }
    }
}

/// Built-in profile registry: frontmost Mac app (from IBAppList /
/// isActive) → profile. Terminals map to the agent suite — iOS cannot
/// see which process runs inside the terminal, so `opencode` / `codex`
/// reached through a terminal get the agent keys by design.
public enum ContextProfiles {

    // Keycodes: ← 123, → 124, ⏎ 36, ⌫ 51, ⎋ 53, Space 49, Tab 48,
    // A 0, S 1, F 3, G 5, C 8, V 9, B 11, W 13, R 15, T 17, N 45, P 35,
    // L 37, I 34, Z 6, [ 33, ] 30, / 44, 1 18, 2 19, 3 20, 4 21.
    // Modifier mask: shift=1, control=2, option=4, command=8.

    public static let presentation = ContextProfile(
        id: "presentation", title: IBLocale.Context.profilePresentation,
        bundleIDs: ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Previous", symbol: "chevron.left", keycode: 123),
            .key(label: "Next", symbol: "chevron.right", keycode: 124),
            .key(label: "Black Screen", symbol: "rectangle.fill", keycode: 11),      // B
            .key(label: "White Screen", symbol: "rectangle", keycode: 13),           // W
            .key(label: "Play / Exit", symbol: "play.fill", keycode: 35, modifiers: 4 | 8),  // ⌥⌘P
            .key(label: "Exit", symbol: "escape", keycode: 53),
        ])

    public static let agent = ContextProfile(
        id: "agent", title: IBLocale.Context.profileAgent,
        bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
            "com.anthropic.claudefordesktop", "com.openai.chat",
        ],
        actions: [
            .voiceHero(label: "Talk to Agent", symbol: "waveform"),
            .key(label: "Approve", symbol: "checkmark", keycode: 36),                // ⏎
            .key(label: "Interrupt", symbol: "xmark", keycode: 8, modifiers: 2),     // ⌃C
            .key(label: "Copy", symbol: "doc.on.doc", keycode: 8, modifiers: 8),     // ⌘C
            .key(label: "Paste", symbol: "doc.on.clipboard", keycode: 9, modifiers: 8), // ⌘V
            .key(label: "Clear", symbol: "eraser", keycode: 37, modifiers: 2),       // ⌃L
            .key(label: "Escape", symbol: "escape", keycode: 53),
        ])

    public static let finder = ContextProfile(
        id: "finder", title: IBLocale.Context.profileFinder,
        bundleIDs: ["com.apple.finder"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Quick Look", symbol: "eye", keycode: 49),                   // Space
            .key(label: "Rename", symbol: "pencil", keycode: 36),                    // ⏎
            .key(label: "New Folder", symbol: "folder.badge.plus", keycode: 45, modifiers: 9),  // ⇧⌘N
            .key(label: "Go to Folder", symbol: "arrow.right.circle", keycode: 5, modifiers: 9), // ⇧⌘G
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),       // ⌘⌫
            .key(label: "New Window", symbol: "macwindow.badge.plus", keycode: 45, modifiers: 8), // ⌘N
        ])

    public static let notes = ContextProfile(
        id: "notes", title: IBLocale.Context.profileNotes,
        bundleIDs: ["com.apple.Notes"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Note", symbol: "square.and.pencil", keycode: 45, modifiers: 8),  // ⌘N
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8),       // ⌘F
            .key(label: "Bold", symbol: "bold", keycode: 11, modifiers: 8),                   // ⌘B
            .key(label: "Italic", symbol: "italic", keycode: 34, modifiers: 8),               // ⌘I
            .key(label: "Checklist", symbol: "checklist", keycode: 37, modifiers: 9),         // ⇧⌘L
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),                // ⌘⌫
        ])

    public static let browser = ContextProfile(
        id: "browser", title: IBLocale.Context.profileBrowser,
        bundleIDs: [
            "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
            "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Tab", symbol: "plus.square", keycode: 17, modifiers: 8),        // ⌘T
            .key(label: "Close Tab", symbol: "xmark.square", keycode: 13, modifiers: 8),     // ⌘W
            .key(label: "Back", symbol: "chevron.backward", keycode: 33, modifiers: 8),      // ⌘[
            .key(label: "Forward", symbol: "chevron.forward", keycode: 30, modifiers: 8),    // ⌘]
            .key(label: "Reload", symbol: "arrow.clockwise", keycode: 15, modifiers: 8),     // ⌘R
            .key(label: "Address Bar", symbol: "text.cursor", keycode: 37, modifiers: 8),    // ⌘L
        ])

    public static let mail = ContextProfile(
        id: "mail", title: IBLocale.Context.profileMail,
        bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Mail", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Reply", symbol: "arrowshape.turn.up.left", keycode: 15, modifiers: 8), // ⌘R
            .key(label: "Archive", symbol: "archivebox", keycode: 0, modifiers: 2 | 8),      // ⌃⌘A
            .key(label: "Delete", symbol: "trash", keycode: 51),                             // ⌫
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 4 | 8),  // ⌥⌘F
            .key(label: "Forward", symbol: "arrowshape.turn.up.right", keycode: 3, modifiers: 9), // ⇧⌘F
        ])

    public static let messages = ContextProfile(
        id: "messages", title: IBLocale.Context.profileMessages,
        bundleIDs: ["com.apple.MobileSMS"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Message", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Send", symbol: "paperplane.fill", keycode: 36),                        // ⏎
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8),         // ⌘F
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),                  // ⌘⌫
        ])

    public static let calendar = ContextProfile(
        id: "calendar", title: IBLocale.Context.profileCalendar,
        bundleIDs: ["com.apple.iCal"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Event", symbol: "calendar.badge.plus", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Today", symbol: "calendar", keycode: 17, modifiers: 8),                // ⌘T
            .key(label: "Day", symbol: "1.square", keycode: 18, modifiers: 8),                  // ⌘1
            .key(label: "Week", symbol: "2.square", keycode: 19, modifiers: 8),                 // ⌘2
            .key(label: "Month", symbol: "3.square", keycode: 20, modifiers: 8),                // ⌘3
            .key(label: "Year", symbol: "4.square", keycode: 21, modifiers: 8),                 // ⌘4
        ])

    public static let editor = ContextProfile(
        id: "editor", title: IBLocale.Context.profileEditor,
        bundleIDs: [
            "com.apple.dt.Xcode", "com.apple.TextEdit", "com.sublimetext.4",
            "com.panic.Nova", "dev.zed.Zed",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Build", symbol: "hammer", keycode: 11, modifiers: 8),        // ⌘B
            .key(label: "Run", symbol: "play.fill", keycode: 15, modifiers: 8),       // ⌘R
            .key(label: "Comment", symbol: "text.bubble", keycode: 44, modifiers: 8), // ⌘/
            .key(label: "Find", symbol: "magnifyingglass", keycode: 3, modifiers: 8), // ⌘F
            .key(label: "Save", symbol: "square.and.arrow.down", keycode: 1, modifiers: 8), // ⌘S
            .key(label: "Undo", symbol: "arrow.uturn.backward", keycode: 6, modifiers: 8),  // ⌘Z
        ])

    /// Fallback for any app without a dedicated suite: system controls.
    public static let console = ContextProfile(
        id: "console", title: IBLocale.Context.profileConsole,
        bundleIDs: [],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .system(label: "Volume +", symbol: "speaker.plus.fill", command: .volumeUp),
            .system(label: "Volume −", symbol: "speaker.minus.fill", command: .volumeDown),
            .system(label: "Mute", symbol: "speaker.slash.fill", command: .volumeMute),
            .system(label: "Play / Pause", symbol: "playpause.fill", command: .mediaPlayPause),
            .system(label: "Brightness +", symbol: "sun.max.fill", command: .brightnessUp),
            .system(label: "Brightness −", symbol: "sun.min.fill", command: .brightnessDown),
            .key(label: "Lock Screen", symbol: "lock.fill", keycode: 12, modifiers: 2 | 8), // ⌃⌘Q
            .system(label: "Safari", symbol: "safari.fill", command: .launchApp),
        ])

    /// Built-in suites, most specific first. A marketplace would append
    /// developer-supplied profiles here (or merge them ahead of these).
    public static let all: [ContextProfile] = [
        presentation, agent, finder, notes, browser, mail, messages, calendar, editor, console,
    ]

    public static func profile(for app: IBAppInfo?) -> ContextProfile {
        guard let app else { return console }
        return all.first { $0.bundleIDs.contains(app.id) } ?? console
    }
}
