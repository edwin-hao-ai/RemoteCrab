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
/// see which process runs inside the terminal, so `opencode` / `codex` /
/// `claude` reached through a terminal get the agent keys by design.
///
/// Shortcuts marked "(menu-verified)" were read straight out of the
/// app's real menu bar with AppleScript (`AXMenuItemCmdChar` /
/// `AXMenuItemCmdModifiers`), not guessed. Electron apps (VSCode,
/// Discord, Lark, …) don't expose their menus to AX, so those use the
/// vendor's documented shortcuts.
public enum ContextProfiles {

    // Keycodes: ← 123, → 124, ↑ 126, ↓ 125, ⏎ 36, ⌫ 51, ⎋ 53, Space 49,
    // ` 50, A 0, B 11, C 8, F 3, G 5, H 4, I 34, L 37, M 46, N 45, O 31,
    // P 35, R 15, S 1, T 17, U 32, V 9, W 13, Z 6, [ 33, ] 30, / 44,
    // - 27, + 24, 0 29, 1 18, 2 19, 3 20, 4 21.
    // Modifier mask: shift=1, control=2, option=4, command=8.

    public static let presentation = ContextProfile(
        id: "presentation", title: IBLocale.Context.profilePresentation,
        bundleIDs: ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Previous", symbol: "chevron.left", keycode: 123),
            .key(label: "Next", symbol: "chevron.right", keycode: 124),
            .key(label: "Black Screen", symbol: "rectangle.fill", keycode: 11),               // B
            .key(label: "White Screen", symbol: "rectangle", keycode: 13),                    // W
            .key(label: "Play / Exit", symbol: "play.fill", keycode: 35, modifiers: 4 | 8),   // ⌥⌘P (menu-verified)
            .key(label: "Exit", symbol: "escape", keycode: 53),
        ])

    public static let agent = ContextProfile(
        id: "agent", title: IBLocale.Context.profileAgent,
        bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
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

    /// GUI AI assistants (Claude/ChatGPT/WorkBuddy/OpenCode/MiniMax). The
    /// terminal keys (⌃C/⌃L) mean nothing here, so this suite is
    /// chat-shaped: send, new, search, copy/paste, stop.
    public static let ai = ContextProfile(
        id: "ai", title: IBLocale.Context.profileAI,
        bundleIDs: [
            "com.anthropic.claudefordesktop", "com.openai.chat",
            "ai.opencode.desktop", "com.minimax.agent.cn",
            "com.workbuddy.workbuddy-ai",
        ],
        actions: [
            .voiceHero(label: "Talk to Agent", symbol: "waveform"),
            .key(label: "Send", symbol: "paperplane.fill", keycode: 36),               // ⏎
            .key(label: "New Chat", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Copy", symbol: "doc.on.doc", keycode: 8, modifiers: 8),       // ⌘C
            .key(label: "Paste", symbol: "doc.on.clipboard", keycode: 9, modifiers: 8), // ⌘V
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8), // ⌘F
            .key(label: "Stop", symbol: "stop.fill", keycode: 53),                      // esc
        ])

    public static let finder = ContextProfile(
        id: "finder", title: IBLocale.Context.profileFinder,
        bundleIDs: ["com.apple.finder"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Quick Look", symbol: "eye", keycode: 49),                   // Space
            .key(label: "Rename", symbol: "pencil", keycode: 36),                    // ⏎
            .key(label: "New Folder", symbol: "folder.badge.plus", keycode: 45, modifiers: 9),   // ⇧⌘N (menu-verified)
            .key(label: "Go to Folder", symbol: "arrow.right.circle", keycode: 5, modifiers: 9),  // ⇧⌘G (menu-verified)
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),       // ⌘⌫ (menu-verified)
            .key(label: "New Window", symbol: "macwindow.badge.plus", keycode: 45, modifiers: 8), // ⌘N (menu-verified)
        ])

    public static let notes = ContextProfile(
        id: "notes", title: IBLocale.Context.profileNotes,
        bundleIDs: ["com.apple.Notes"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Note", symbol: "square.and.pencil", keycode: 45, modifiers: 8),  // ⌘N (menu-verified)
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8),       // ⌘F
            .key(label: "Bold", symbol: "bold", keycode: 11, modifiers: 8),                   // ⌘B
            .key(label: "Italic", symbol: "italic", keycode: 34, modifiers: 8),               // ⌘I
            .key(label: "Checklist", symbol: "checklist", keycode: 37, modifiers: 9),         // ⇧⌘L (menu-verified)
            .key(label: "New Folder", symbol: "folder.badge.plus", keycode: 45, modifiers: 9), // ⇧⌘N (menu-verified)
        ])

    public static let browser = ContextProfile(
        id: "browser", title: IBLocale.Context.profileBrowser,
        bundleIDs: [
            "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
            "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Tab", symbol: "plus.square", keycode: 17, modifiers: 8),        // ⌘T (menu-verified)
            .key(label: "Close Tab", symbol: "xmark.square", keycode: 13, modifiers: 8),     // ⌘W (menu-verified)
            .key(label: "Back", symbol: "chevron.backward", keycode: 33, modifiers: 8),      // ⌘[ (menu-verified)
            .key(label: "Forward", symbol: "chevron.forward", keycode: 30, modifiers: 8),    // ⌘] (menu-verified)
            .key(label: "Reload", symbol: "arrow.clockwise", keycode: 15, modifiers: 8),     // ⌘R (menu-verified)
            .key(label: "Address Bar", symbol: "text.cursor", keycode: 37, modifiers: 8),    // ⌘L (menu-verified)
        ])

    public static let mail = ContextProfile(
        id: "mail", title: IBLocale.Context.profileMail,
        bundleIDs: ["com.apple.mail", "com.microsoft.Outlook"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Mail", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N (menu-verified)
            .key(label: "Reply", symbol: "arrowshape.turn.up.left", keycode: 15, modifiers: 8), // ⌘R (menu-verified)
            .key(label: "Archive", symbol: "archivebox", keycode: 0, modifiers: 2 | 8),      // ⌃⌘A (menu-verified)
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),               // ⌘⌫ (menu-verified)
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 4 | 8),  // ⌥⌘F
            .key(label: "Forward", symbol: "arrowshape.turn.up.right", keycode: 3, modifiers: 9), // ⇧⌘F
        ])

    public static let messages = ContextProfile(
        id: "messages", title: IBLocale.Context.profileMessages,
        bundleIDs: ["com.apple.MobileSMS"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Message", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Send", symbol: "paperplane.fill", keycode: 36, modifiers: 8),          // ⌘⏎ (menu-verified)
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8),         // ⌘F
            .key(label: "Delete", symbol: "trash", keycode: 51, modifiers: 8),                  // ⌘⌫
        ])

    public static let calendar = ContextProfile(
        id: "calendar", title: IBLocale.Context.profileCalendar,
        bundleIDs: ["com.apple.iCal"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Event", symbol: "calendar.badge.plus", keycode: 45, modifiers: 8), // ⌘N (menu-verified)
            .key(label: "Today", symbol: "calendar", keycode: 17, modifiers: 8),                // ⌘T (menu-verified)
            .key(label: "Day", symbol: "1.square", keycode: 18, modifiers: 8),                  // ⌘1 (menu-verified)
            .key(label: "Week", symbol: "2.square", keycode: 19, modifiers: 8),                 // ⌘2 (menu-verified)
            .key(label: "Month", symbol: "3.square", keycode: 20, modifiers: 8),                // ⌘3 (menu-verified)
            .key(label: "Year", symbol: "4.square", keycode: 21, modifiers: 8),                 // ⌘4 (menu-verified)
        ])

    /// Xcode only — its ⌘B/⌘R mean build/run, which differ from a plain
    /// code editor (see `editor`) and a rich-text editor (see `text`).
    public static let xcode = ContextProfile(
        id: "xcode", title: IBLocale.Context.profileXcode,
        bundleIDs: ["com.apple.dt.Xcode"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Build", symbol: "hammer", keycode: 11, modifiers: 8),        // ⌘B
            .key(label: "Run", symbol: "play.fill", keycode: 15, modifiers: 8),       // ⌘R (menu-verified)
            .key(label: "Save", symbol: "square.and.arrow.down", keycode: 1, modifiers: 8), // ⌘S (menu-verified)
            .key(label: "Find", symbol: "magnifyingglass", keycode: 3, modifiers: 8), // ⌘F (menu-verified)
            .key(label: "Comment", symbol: "text.bubble", keycode: 44, modifiers: 8), // ⌘/
            .key(label: "Undo", symbol: "arrow.uturn.backward", keycode: 6, modifiers: 8),  // ⌘Z
        ])

    /// Code editors that aren't Xcode. ⌘B toggles the sidebar here, so we
    /// lead with the palette/quick-open/terminal keys instead.
    public static let editor = ContextProfile(
        id: "editor", title: IBLocale.Context.profileEditor,
        bundleIDs: [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", // Cursor
            "com.sublimetext.4", "com.panic.Nova", "dev.zed.Zed",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Command Palette", symbol: "command", keycode: 35, modifiers: 9),   // ⇧⌘P
            .key(label: "Quick Open", symbol: "doc.text.magnifyingglass", keycode: 31, modifiers: 8), // ⌘P
            .key(label: "Terminal", symbol: "terminal", keycode: 50, modifiers: 2),         // ⌃`
            .key(label: "Comment", symbol: "text.bubble", keycode: 44, modifiers: 8),       // ⌘/
            .key(label: "Find", symbol: "magnifyingglass", keycode: 3, modifiers: 8),       // ⌘F
            .key(label: "Save", symbol: "square.and.arrow.down", keycode: 1, modifiers: 8), // ⌘S
        ])

    /// Rich-text / document editors (TextEdit, Pages, Numbers, Word) —
    /// ⌘B is BOLD here.
    public static let text = ContextProfile(
        id: "text", title: IBLocale.Context.profileText,
        bundleIDs: [
            "com.apple.TextEdit", "com.apple.iWork.Pages",
            "com.apple.iWork.Numbers", "com.microsoft.Word",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Bold", symbol: "bold", keycode: 11, modifiers: 8),           // ⌘B
            .key(label: "Italic", symbol: "italic", keycode: 34, modifiers: 8),       // ⌘I
            .key(label: "Underline", symbol: "underline", keycode: 32, modifiers: 8), // ⌘U
            .key(label: "Find", symbol: "magnifyingglass", keycode: 3, modifiers: 8), // ⌘F
            .key(label: "Save", symbol: "square.and.arrow.down", keycode: 1, modifiers: 8), // ⌘S
            .key(label: "Print", symbol: "printer", keycode: 35, modifiers: 8),       // ⌘P (menu-verified)
        ])

    /// Now-playing controls (Music / Spotify).
    public static let media = ContextProfile(
        id: "media", title: IBLocale.Context.profileMedia,
        bundleIDs: ["com.apple.Music", "com.spotify.client"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Previous Track", symbol: "backward.fill", keycode: 123, modifiers: 8), // ⌘← (menu-verified)
            .key(label: "Next Track", symbol: "forward.fill", keycode: 124, modifiers: 8),      // ⌘→ (menu-verified)
            .key(label: "Volume Down", symbol: "speaker.minus.fill", keycode: 125, modifiers: 8), // ⌘↓ (menu-verified)
            .key(label: "Volume Up", symbol: "speaker.plus.fill", keycode: 126, modifiers: 8),  // ⌘↑ (menu-verified)
            .key(label: "Play / Pause", symbol: "playpause.fill", keycode: 49),           // Space (menu-verified)
            .key(label: "Mini Player", symbol: "rectangle.compress.vertical", keycode: 46, modifiers: 9), // ⇧⌘M
        ])

    /// Chat apps. Send is ⏎ everywhere; the rest follow each vendor's
    /// documented shortcuts (Electron menus aren't readable via AX).
    public static let chat = ContextProfile(
        id: "chat", title: IBLocale.Context.profileChat,
        bundleIDs: [
            "com.hnc.Discord", "com.tinyspeck.slackmacgap",
            "com.electron.lark", "com.tencent.xinWeChat", "org.telegram.desktop",
        ],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Send", symbol: "paperplane.fill", keycode: 36),                 // ⏎
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8), // ⌘F
            .key(label: "New Message", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N
            .key(label: "Mute", symbol: "mic.slash.fill", keycode: 46, modifiers: 9),   // ⇧⌘M
        ])

    /// Video meetings. Zoom-centric (Teams/腾讯会议 differ); mute and
    /// camera are the two that matter mid-call.
    public static let meeting = ContextProfile(
        id: "meeting", title: IBLocale.Context.profileMeeting,
        bundleIDs: ["us.zoom.xos", "com.microsoft.teams2", "com.tencent.meeting"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Mute", symbol: "mic.slash.fill", keycode: 0, modifiers: 9),      // ⌘⇧A (Zoom)
            .key(label: "Camera", symbol: "video.fill", keycode: 9, modifiers: 9),        // ⌘⇧V (Zoom)
            .key(label: "Share Screen", symbol: "rectangle.on.rectangle", keycode: 1, modifiers: 9), // ⌘⇧S
            .key(label: "Leave", symbol: "phone.down.fill", keycode: 4, modifiers: 9),    // ⌘⇧H
        ])

    /// Image / video viewers.
    public static let image = ContextProfile(
        id: "image", title: IBLocale.Context.profileImage,
        bundleIDs: ["com.apple.Preview", "com.apple.Photos", "com.apple.QuickTimePlayerX"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "Previous Image", symbol: "chevron.left", keycode: 123),
            .key(label: "Next Image", symbol: "chevron.right", keycode: 124),
            .key(label: "Zoom In", symbol: "plus.magnifyingglass", keycode: 24, modifiers: 8),  // ⌘+
            .key(label: "Zoom Out", symbol: "minus.magnifyingglass", keycode: 27, modifiers: 8), // ⌘-
            .key(label: "Actual Size", symbol: "1.magnifyingglass", keycode: 29, modifiers: 8), // ⌘0
            .key(label: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right", keycode: 3, modifiers: 2 | 8), // ⌃⌘F
        ])

    /// Markdown / note apps (Obsidian-style keymap).
    public static let notebook = ContextProfile(
        id: "notebook", title: IBLocale.Context.profileNotebook,
        bundleIDs: ["md.obsidian", "notion.id", "net.shinyfrog.bear"],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .key(label: "New Note", symbol: "square.and.pencil", keycode: 45, modifiers: 8), // ⌘N (menu-verified)
            .key(label: "Quick Open", symbol: "doc.text.magnifyingglass", keycode: 31, modifiers: 8), // ⌘O
            .key(label: "Command Palette", symbol: "command", keycode: 35, modifiers: 8),  // ⌘P
            .key(label: "Search", symbol: "magnifyingglass", keycode: 3, modifiers: 8),   // ⌘F
        ])

    /// Fallback for any app without a dedicated suite: system controls.
    public static let console = ContextProfile(
        id: "console", title: IBLocale.Context.profileConsole,
        bundleIDs: [],
        actions: [
            .voiceHero(label: "Talk to Mac", symbol: "waveform"),
            .system(label: "Volume Up", symbol: "speaker.plus.fill", command: .volumeUp),
            .system(label: "Volume Down", symbol: "speaker.minus.fill", command: .volumeDown),
            .system(label: "Mute", symbol: "speaker.slash.fill", command: .volumeMute),
            .system(label: "Play / Pause", symbol: "playpause.fill", command: .mediaPlayPause),
            .system(label: "Brightness Up", symbol: "sun.max.fill", command: .brightnessUp),
            .system(label: "Brightness Down", symbol: "sun.min.fill", command: .brightnessDown),
            .key(label: "Lock Screen", symbol: "lock.fill", keycode: 12, modifiers: 2 | 8), // ⌃⌘Q
            .system(label: "Safari", symbol: "safari.fill", command: .launchApp),
        ])

    /// Built-in suites, most specific first. A marketplace would append
    /// developer-supplied profiles here (or merge them ahead of these).
    public static let all: [ContextProfile] = [
        presentation, agent, ai, finder, notes, browser, mail, messages, calendar,
        xcode, editor, text, media, chat, meeting, image, notebook, console,
    ]

    public static func profile(for app: IBAppInfo?) -> ContextProfile {
        guard let app else { return console }
        return all.first { $0.bundleIDs.contains(app.id) } ?? console
    }
}
