import XCTest
@testable import RemoteCrabCore

final class ContextProfilesTests: XCTestCase {
    private func app(_ id: String, name: String = "x") -> IBAppInfo {
        IBAppInfo(id: id, name: name, pid: 1, isActive: true, iconPNG: nil)
    }

    func testKeynoteMatchesPresentation() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.iWork.Keynote")).id, "presentation")
    }

    func testPowerPointMatchesPresentation() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.microsoft.Powerpoint")).id, "presentation")
    }

    func testTerminalMatchesAgent() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Terminal")).id, "agent")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.googlecode.iterm2")).id, "agent")
        XCTAssertEqual(ContextProfiles.profile(for: app("com.mitchellh.ghostty")).id, "agent")
    }

    func testUnknownFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: app("com.apple.Safari")).id, "console")
    }

    func testNilFallsBackToConsole() {
        XCTAssertEqual(ContextProfiles.profile(for: nil).id, "console")
    }

    func testConsoleHasVolumeAndMediaActions() {
        let console = ContextProfiles.profile(for: nil)
        let commands = console.actions.compactMap { action -> IBSystemCommand.Command? in
            if case .system(_, _, let c) = action { return c }
            return nil
        }
        XCTAssertTrue(commands.contains(.volumeUp))
        XCTAssertTrue(commands.contains(.mediaPlayPause))
    }

    func testAgentSuiteHasVoiceHero() {
        let agent = ContextProfiles.profile(for: app("com.apple.Terminal"))
        XCTAssertTrue(agent.actions.contains { if case .voiceHero = $0 { return true }; return false })
    }
}
