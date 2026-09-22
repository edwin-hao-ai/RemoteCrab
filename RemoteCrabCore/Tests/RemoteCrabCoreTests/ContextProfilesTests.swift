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
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iWork.Keynote")).id, "presentation")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.microsoft.Powerpoint")).id, "presentation")
    }

    func testTerminalsMatchAgent() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2",
                   "com.mitchellh.ghostty", "dev.warp.Warp-Stable"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "agent", id)
        }
    }

    func testAgentClientsMatchAgent() {
        for id in ["com.anthropic.claudefordesktop", "com.openai.chat",
                   "ai.opencode.desktop", "com.minimax.agent.cn"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "agent", id)
        }
    }

    func testCodeEditorsMatchEditor() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                   "com.sublimetext.4", "com.panic.Nova", "dev.zed.Zed"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "editor", id)
        }
    }

    func testXcodeMatchesXcode() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.dt.Xcode")).id, "xcode")
    }

    func testRichTextMatchesText() {
        for id in ["com.apple.TextEdit", "com.apple.iWork.Pages",
                   "com.apple.iWork.Numbers", "com.microsoft.Word"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "text", id)
        }
    }

    func testMediaChatMeetingMatch() {
        for id in ["com.apple.Music", "com.spotify.client"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "media", id)
        }
        for id in ["com.hnc.Discord", "com.tinyspeck.slackmacgap",
                   "com.electron.lark", "com.tencent.xinWeChat", "org.telegram.desktop"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "chat", id)
        }
        for id in ["us.zoom.xos", "com.microsoft.teams2", "com.tencent.meeting"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "meeting", id)
        }
    }

    func testImageAndNotebookMatch() {
        for id in ["com.apple.Preview", "com.apple.Photos", "com.apple.QuickTimePlayerX"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "image", id)
        }
        for id in ["md.obsidian", "notion.id", "net.shinyfrog.bear"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "notebook", id)
        }
    }

    func testFinderMatchesFinder() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.finder")).id, "finder")
    }

    func testNotesMatchesNotes() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Notes")).id, "notes")
    }

    func testBrowsersMatchBrowser() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                   "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "browser", id)
        }
    }

    func testMailMatchesMail() {
        for id in ["com.apple.mail", "com.microsoft.Outlook"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "mail", id)
        }
    }

    func testMessagesAndCalendar() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.MobileSMS")).id, "messages")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iCal")).id, "calendar")
    }

    func testEditorsMatchEditor() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertEqual(ContextProfiles.profile(for: app(id)).id, "editor", id)
        }
    }

    func testUnknownFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.example.unknown")).id, "console")
    }

    func testNilFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: nil).id, "console")
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
}
