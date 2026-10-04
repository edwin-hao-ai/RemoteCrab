import XCTest
@testable import RemoteCrabCore

final class ContextProfilesTests: XCTestCase {
    private func app(_ id: String, name: String = "x") -> IBAppInfo {
        IBAppInfo(id: id, name: name, pid: 1, isActive: true, iconPNG: nil)
    }

    private func systemCommand(_ action: ContextAction) -> IBSystemCommand.Command? {
        if case .system(_, _, let c) = action { return c }
        return nil
    }

    // MARK: - Frontmost-app → profile

    func testKeynoteMatchesPresentation() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iWork.Keynote"), platform: .mac).id, "presentation")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.microsoft.Powerpoint"), platform: .mac).id, "presentation")
    }

    func testTerminalsMatchAgent() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2",
                   "com.mitchellh.ghostty", "dev.warp.Warp-Stable"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "agent", id)
        }
    }

    func testAgentClientsMatchAI() {
        for id in ["com.anthropic.claudefordesktop", "com.openai.chat",
                   "com.minimax.agent.cn", "com.workbuddy.workbuddy-ai"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "ai", id)
        }
    }

    func testOpenCodeMatchesOpenCode() {
        XCTAssertEqual(ContextProfiles.profile(for: app("ai.opencode.desktop"), platform: .mac).id, "opencode")
    }

    /// OpenCode's real shortcuts (read from its Electron keybind table):
    /// New Session is ⇧⌘S (not ⌘N), session nav is ⌥↑/⌥↓.
    func testOpenCodeSessionKeys() {
        let keys = ContextProfiles.opencode.gridActions.compactMap { action -> (UInt16, UInt8)? in
            if case .key(_, _, let kc, let mods) = action { return (kc, mods) }
            return nil
        }
        XCTAssertTrue(keys.contains { $0 == (1, 1 | 8) })   // New Session ⇧⌘S
        XCTAssertTrue(keys.contains { $0 == (126, 4) })     // Previous Session ⌥↑
        XCTAssertTrue(keys.contains { $0 == (125, 4) })     // Next Session ⌥↓
    }

    func testCodeEditorsMatchEditor() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                   "com.sublimetext.4", "com.panic.Nova", "dev.zed.Zed"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "editor", id)
        }
    }

    func testXcodeMatchesXcode() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.dt.Xcode"), platform: .mac).id, "xcode")
    }

    func testRichTextMatchesText() {
        for id in ["com.apple.TextEdit", "com.apple.iWork.Pages",
                   "com.apple.iWork.Numbers", "com.microsoft.Word"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "text", id)
        }
    }

    func testMediaChatMeetingMatch() {
        for id in ["com.apple.Music", "com.spotify.client"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "media", id)
        }
        for id in ["com.hnc.Discord", "com.tinyspeck.slackmacgap",
                   "com.electron.lark", "com.tencent.xinWeChat", "org.telegram.desktop"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "chat", id)
        }
        for id in ["us.zoom.xos", "com.microsoft.teams2", "com.tencent.meeting"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "meeting", id)
        }
    }

    func testImageAndNotebookMatch() {
        for id in ["com.apple.Preview", "com.apple.Photos", "com.apple.QuickTimePlayerX"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "image", id)
        }
        for id in ["md.obsidian", "notion.id", "net.shinyfrog.bear"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "notebook", id)
        }
    }

    func testFinderMatchesFinder() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.finder"), platform: .mac).id, "finder")
    }

    func testNotesMatchesNotes() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Notes"), platform: .mac).id, "notes")
    }

    func testBrowsersMatchBrowser() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                   "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "browser", id)
        }
    }

    func testMailMatchesMail() {
        for id in ["com.apple.mail", "com.microsoft.Outlook"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "mail", id)
        }
    }

    func testMessagesAndCalendar() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.MobileSMS"), platform: .mac).id, "messages")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iCal"), platform: .mac).id, "calendar")
    }

    func testEditorsMatchEditor() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id), platform: .mac).id, "editor", id)
        }
    }

    func testUnknownFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.example.unknown"), platform: .mac).id, "console")
    }

    func testNilFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: nil, platform: .mac).id, "console")
    }

    // MARK: - Structure invariants

    func testBundleIDsAreUniqueAcrossProfiles() {
        var seen = Set<String>()
        for profile in ContextProfiles.all {
            for id in profile.bundleIDs {
                XCTAssertTrue(seen.insert(id).inserted, "\(id) appears in more than one profile")
            }
        }
    }

    func testEveryProfileHasVoiceHero() {
        for profile in ContextProfiles.all {
            XCTAssertNotNil(profile.voiceHero, "\(profile.id) has no voice hero")
        }
    }

    func testGridActionsExcludeVoiceHero() {
        for profile in ContextProfiles.all {
            XCTAssertEqual(profile.gridActions.count, profile.actions.count - 1, profile.id)
            XCTAssertFalse(profile.gridActions.contains {
                if case .voiceHero = $0 { return true }
                return false
            }, profile.id)
        }
    }

    /// The grid is two columns, so an even number of actions pairs every
    /// row cleanly (no lonely half-row at the bottom).
    func testEveryProfileHasEvenGridActionCount() {
        for profile in ContextProfiles.all {
            XCTAssertEqual(profile.gridActions.count % 2, 0,
                           "\(profile.id) has \(profile.gridActions.count) grid actions")
        }
    }

    /// The sheet lays grid actions out two-per-row, so related controls
    /// must sit on the SAME row (adjacent, first at an even index).
    func testConsolePairsRelatedActionsInRows() {
        let grid = ContextProfiles.console.gridActions
        XCTAssertGreaterThanOrEqual(grid.count, 6)
        XCTAssertEqual(systemCommand(grid[0]), .volumeUp)
        XCTAssertEqual(systemCommand(grid[1]), .volumeDown)
        XCTAssertEqual(systemCommand(grid[2]), .volumeMute)
        XCTAssertEqual(systemCommand(grid[3]), .mediaPlayPause)
        XCTAssertEqual(systemCommand(grid[4]), .brightnessUp)
        XCTAssertEqual(systemCommand(grid[5]), .brightnessDown)
    }

    func testConsoleHasVolumeAndMediaActions() {
        let commands = ContextProfiles.console.gridActions.compactMap(systemCommand)
        XCTAssertTrue(commands.contains(.volumeUp))
        XCTAssertTrue(commands.contains(.mediaPlayPause))
        XCTAssertTrue(commands.contains(.brightnessUp))
    }

    func testAgentSuiteHasApproveAndInterrupt() {
        let codes = ContextProfiles.agent.gridActions.compactMap { action -> UInt16? in
            if case .key(_, _, let kc, _) = action { return kc }
            return nil
        }
        XCTAssertTrue(codes.contains(36))   // ⏎ approve
        XCTAssertTrue(codes.contains(8))    // ⌃C interrupt
    }

    // MARK: - Marketplace-forward: profiles are serializable

    func testProfileCodableRoundTrip() throws {
        for profile in ContextProfiles.all {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(ContextProfile.self, from: data)
            XCTAssertEqual(decoded, profile, profile.id)
        }
    }

    // MARK: - Windows matching (mechanism)
    //
    // These use a synthetic registry on purpose: which real suites ship
    // Windows mappings is data, pinned in ContextWindowsSuiteTests.

    private func win(_ name: String) -> IBAppInfo {
        IBAppInfo(id: "pid:1234", name: name, pid: 1234, isActive: true, iconPNG: nil)
    }

    private func registry() -> [ContextProfile] {
        [
            ContextProfile(id: "term", title: "Terminal",
                           actions: [.key(label: "Stop", symbol: "stop.fill", keycode: 53)],
                           windowsProcessNames: ["WindowsTerminal", "cmd"],
                           windowsActions: [.key(label: "Stop", symbol: "stop.fill", keycode: 53)]),
            ContextProfile(id: "maconly", title: "Mac only",
                           bundleIDs: ["com.example.mac"],
                           actions: [.key(label: "Go", symbol: "arrow.right", keycode: 123)]),
        ]
    }

    /// Windows 的 `id` 是字面量 "pid:1234"，每次启动都变。匹配必须走
    /// 进程名，且这个 id 绝不能参与匹配。
    func testWindowsMatchesOnProcessName() {
        XCTAssertEqual(
            ContextProfiles.profile(for: win("WindowsTerminal"), platform: .windows,
                                    in: registry()).id, "term")
    }

    func testWindowsProcessNameMatchIsCaseInsensitiveAndStripsExe() {
        for spelling in ["WindowsTerminal", "windowsterminal", "WINDOWSTERMINAL.EXE"] {
            XCTAssertEqual(
                ContextProfiles.profile(for: win(spelling), platform: .windows,
                                        in: registry()).id, "term", spelling)
        }
    }

    /// 一个只有 Mac 名单的套件，在 Windows 上绝不能因为名字碰巧一样而命中。
    func testWindowsIgnoresMacBundleIdentifiers() {
        let p = ContextProfiles.profile(for: win("com.example.mac"), platform: .windows,
                                        in: registry())
        XCTAssertEqual(p.id, "console")
    }

    func testWindowsUnknownAppFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: win("zzz"), platform: .windows,
                                               in: registry()).id, "console")
    }

    /// 核心不变量：一个没有 Windows 映射的套件，在 Windows 上必须渲染成
    /// **空的应用区**，而不是借用 Mac 的按键。Mac 的动作是对着 Mac 菜单栏
    /// 核对过的，在 Windows 上 ⌘ 塌缩成 ⌃ —— 借过来得到的是「错按钮」，
    /// 包括一个会中断的「复制」和一个会退出程序的「锁定屏幕」。
    func testASuiteWithNoWindowsMappingResolvesToNoWindowsActions() {
        let macOnly = ContextProfiles.profile(for: app("com.example.mac"), platform: .mac, in: registry())
        XCTAssertNil(macOnly.windowsActions)
        // And the renderer is handed an empty list, never `actions`.
        let rendered = macOnly.windowsActions ?? []
        XCTAssertTrue(rendered.isEmpty)
    }

    // MARK: - Per-platform system actions

    private func systemCommands(_ actions: [ContextAction]) -> [IBSystemCommand.Command] {
        actions.compactMap { action in
            if case .system(_, _, let c) = action { return c }
            if case .systemArg(_, _, let c, _) = action { return c }
            return nil
        }
    }

    /// `system_keys.rs` 对亮度直接 `return false`。留着按钮就是留一个
    /// 点了没反应的东西——比没有更糟（规则 1）。
    func testWindowsSystemActionsHaveNoBrightness() {
        let commands = systemCommands(ContextProfiles.systemActions(for: .windows))
        XCTAssertFalse(commands.contains(.brightnessUp))
        XCTAssertFalse(commands.contains(.brightnessDown))
    }

    func testWindowsSystemActionsKeepTheKeysThatActuallyWork() {
        let commands = systemCommands(ContextProfiles.systemActions(for: .windows))
        XCTAssertTrue(commands.contains(.volumeUp))
        XCTAssertTrue(commands.contains(.volumeMute))
        XCTAssertTrue(commands.contains(.mediaPlayPause))
    }

    /// ⌃⌘Q 会塌缩成 Ctrl+Q（在很多软件里是「退出」）。锁屏必须是 ⊞L。
    func testWindowsLockScreenIsWinLNotCtrlQ() {
        let keys = ContextProfiles.systemActions(for: .windows).compactMap { action -> (UInt16, UInt8)? in
            if case .key(_, _, let kc, let mods) = action { return (kc, mods) }
            return nil
        }
        let lock = keys.first { $0.0 == 37 }   // 37 = L
        XCTAssertEqual(lock?.1, TouchEvent.Modifier.meta.rawValue)
        // The old encoding must be gone: ⌃⌘Q (keycode 12, bits 2|8).
        XCTAssertFalse(keys.contains { $0.0 == 12 && $0.1 == (2 | 8) })
    }

    /// Mac 侧的排列顺序被 testConsolePairsRelatedActionsInRows 按下标钉住，
    /// 这里保证新的平台分支没有动它。
    func testMacSystemActionsAreExactlyTheConsoleGrid() {
        XCTAssertEqual(ContextProfiles.systemActions(for: .mac),
                       ContextProfiles.console.gridActions)
    }

    /// 标签与参数必须成对 —— 旧的 bug 就是「标签写 Safari、参数传 bing」。
    func testLaunchLabelsAndArgumentsAgreeOnBothPlatforms() {
        for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
            for action in ContextProfiles.systemActions(for: platform) {
                guard case .systemArg(let label, _, let cmd, let argument) = action,
                      cmd == .launchApp else { continue }
                if label == "Safari" {
                    XCTAssertEqual(argument, "com.apple.Safari", "\(platform)")
                } else {
                    XCTAssertNotEqual(argument, "com.apple.Safari",
                                      "\(platform): non-Safari button opens Safari")
                }
            }
        }
    }

    // MARK: - Precedence

    func testUserFileOverridesBuiltinById() {
        let override = ContextProfile(id: "agent", title: "My Agent", source: .userFile,
                                      actions: [.voiceHero(label: "T", symbol: "waveform")])
        let merged = ContextProfiles.merged([override])
        XCTAssertEqual(merged.first { $0.id == "agent" }?.title, "My Agent")
        XCTAssertEqual(merged.filter { $0.id == "agent" }.count, 1)
    }

    func testUserFileOutranksRemote() {
        let r = ContextProfile(id: "agent", title: "Remote", source: .remote, actions: [])
        let u = ContextProfile(id: "agent", title: "User", source: .userFile, actions: [])
        XCTAssertEqual(ContextProfiles.merged([r, u]).first { $0.id == "agent" }?.title, "User")
        XCTAssertEqual(ContextProfiles.merged([u, r]).first { $0.id == "agent" }?.title, "User")
    }

    func testRemoteOverridesBuiltinButNotAUserFile() {
        let r = ContextProfile(id: "agent", title: "Remote", source: .remote, actions: [])
        XCTAssertEqual(ContextProfiles.merged([r]).first { $0.id == "agent" }?.title, "Remote")
    }

    /// 一个 `.builtin` 标记的外部套件不该被当成用户安装的——那会让优先级
    /// 取决于调用方忘了改 source。
    func testAnExtraBuiltinIsNotTreatedAsAnOverride() {
        let sneaky = ContextProfile(id: "agent", title: "Sneaky", actions: [])
        XCTAssertEqual(ContextProfiles.merged([sneaky]).first { $0.id == "agent" }?.title,
                       IBLocale.Context.profileAgent)
    }

    /// 合并后的列表仍然要能正常匹配 —— 否则装了就等于没装。
    func testAMergedOverrideStillMatchesItsApp() {
        let override = ContextProfile(
            id: "agent", title: "My Agent", source: .userFile,
            bundleIDs: ["com.apple.Terminal"],
            actions: [.voiceHero(label: "T", symbol: "waveform")])
        let merged = ContextProfiles.merged([override])
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Terminal"), platform: .mac, in: merged).id,
                       "agent")
    }
}
