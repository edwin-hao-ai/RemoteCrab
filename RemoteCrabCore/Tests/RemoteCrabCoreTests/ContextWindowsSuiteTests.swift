import XCTest
@testable import RemoteCrabCore

/// Which suites ship a Windows mapping.
///
/// This is deliberately a **closed, small** list. Every entry's shortcut
/// had to come from a published keybinding table, because none of it can
/// be checked from a Mac — and on Windows a borrowed Mac shortcut is not
/// a missing button but a wrong one (⌘ collapses into ⌃, so the agent
/// suite's ⌃C "Interrupt" and ⌘C "Copy" become the same keystroke).
///
/// A suite absent from this list is not a gap: it falls through to the
/// system console, which is honest and works. Adding one costs a
/// documented source, and the checklist in
/// `docs/WINDOWS-GAPS-2026-10-03.md` records what is still unverified.
final class ContextWindowsSuiteTests: XCTestCase {

    private func win(_ name: String) -> IBAppInfo {
        IBAppInfo(id: "pid:1234", name: name, pid: 1234, isActive: true, iconPNG: nil)
    }

    private func keys(_ profile: ContextProfile) -> [(UInt16, UInt8)] {
        (profile.windowsActions ?? []).compactMap { action in
            if case .key(_, _, let kc, let mods) = action { return (kc, mods) }
            return nil
        }
    }

    /// ⌃C and ⌘C both become Ctrl on Windows (keymap.rs ORs the two bits).
    /// That is how the Mac agent suite's "Copy" button ended up sending
    /// Ctrl+C — which interrupts in a terminal. This test exists so that
    /// class of bug cannot come back.
    func testNoTwoWindowsActionsCollapseToTheSameKeystroke() {
        for profile in ContextProfiles.all {
            guard let actions = profile.windowsActions else { continue }
            var seen = Set<String>()
            for action in actions {
                guard case .key(_, _, let kc, let mods) = action else { continue }
                let ctrl = (mods & 8) != 0 || (mods & 2) != 0
                let normalized = "\(kc)|ctrl:\(ctrl)|alt:\(mods & 4)|shift:\(mods & 1)|meta:\(mods & 16)"
                XCTAssertTrue(seen.insert(normalized).inserted,
                              "\(profile.id): two actions collapse to \(normalized) on Windows")
            }
        }
    }

    /// Two-column grid, so an odd count leaves a lonely half-row.
    func testEveryWindowsActionSetHasAnEvenGridCount() {
        for profile in ContextProfiles.all {
            guard let actions = profile.windowsActions else { continue }
            let grid = actions.filter { if case .voiceHero = $0 { return false }; return true }
            XCTAssertEqual(grid.count % 2, 0,
                           "\(profile.id) has \(grid.count) Windows grid actions")
            XCTAssertNotNil(profile.voiceHero ?? actions.first { if case .voiceHero = $0 { return true }; return false },
                            "\(profile.id) has no Windows voice hero")
        }
    }

    /// A suite with a Windows mapping must actually be reachable by name.
    func testEveryWindowsMappingIsReachable() {
        for profile in ContextProfiles.all {
            guard let names = profile.windowsProcessNames else { continue }
            XCTAssertFalse(names.isEmpty, "\(profile.id) has an empty name list")
            for name in names {
                XCTAssertEqual(
                    ContextProfiles.profile(for: win(name), platform: .windows).id,
                    profile.id,
                    "\(profile.id) lists \(name) but does not match it")
            }
        }
    }

    /// Exe stems must not carry a suffix or stray case into the data —
    /// matching normalizes, but the stored value should still be clean.
    func testWindowsProcessNamesAreBareStems() {
        for profile in ContextProfiles.all {
            for name in profile.windowsProcessNames ?? [] {
                XCTAssertFalse(name.lowercased().hasSuffix(".exe"), "\(profile.id): \(name)")
                XCTAssertEqual(name, name.trimmingCharacters(in: .whitespaces), "\(profile.id): \(name)")
            }
        }
    }

    // MARK: - The suites we ship

    func testTerminalAgentsMatchTheAgentSuite() {
        for exe in ["WindowsTerminal", "powershell", "pwsh", "cmd", "conhost"] {
            XCTAssertEqual(ContextProfiles.profile(for: win(exe), platform: .windows).id,
                           "agent", exe)
        }
    }

    /// Only keys whose Windows behaviour is documented. Copy and paste are
    /// absent on purpose — see the handover checklist.
    func testAgentSuiteShipsOnlyDocumentedWindowsKeys() {
        let p = ContextProfiles.agent
        let shipped = keys(p)
        XCTAssertTrue(shipped.contains { $0.0 == 36 && $0.1 == 0 })   // Enter  = approve
        XCTAssertTrue(shipped.contains { $0.0 == 53 && $0.1 == 0 })   // Esc    = stop
        XCTAssertTrue(shipped.contains { $0.0 == 8 && $0.1 == 2 })    // Ctrl+C = interrupt
        XCTAssertTrue(shipped.contains { $0.0 == 37 && $0.1 == 2 })   // Ctrl+L = clear
        // Nothing beyond those four.
        XCTAssertEqual(shipped.count, 4, "unverified Windows keys leaked into the agent suite")
    }

    func testEditorSuiteMatchesWindowsEditors() {
        for exe in ["Code", "devenv", "cursor", "notepad++"] {
            XCTAssertEqual(ContextProfiles.profile(for: win(exe), platform: .windows).id,
                           "editor", exe)
        }
    }

    func testEditorSuiteShipsVsCodeShortcuts() {
        let shipped = keys(ContextProfiles.editor)
        // VS Code's documented defaults.
        XCTAssertTrue(shipped.contains { $0.0 == 35 && $0.1 == 3 })   // Ctrl+Shift+P palette
        XCTAssertTrue(shipped.contains { $0.0 == 3 && $0.1 == 2 })    // Ctrl+F
        XCTAssertTrue(shipped.contains { $0.0 == 1 && $0.1 == 2 })    // Ctrl+S
        XCTAssertTrue(shipped.contains { $0.0 == 50 && $0.1 == 2 })   // Ctrl+`
        XCTAssertTrue(shipped.contains { $0.0 == 35 && $0.1 == 2 })   // Ctrl+P quick open
    }

    func testBrowserSuiteMatchesWindowsBrowsers() {
        for exe in ["chrome", "msedge", "firefox", "brave"] {
            XCTAssertEqual(ContextProfiles.profile(for: win(exe), platform: .windows).id,
                           "browser", exe)
        }
    }

    func testBrowserSuiteShipsUniversalTabShortcuts() {
        let shipped = keys(ContextProfiles.browser)
        XCTAssertTrue(shipped.contains { $0.0 == 24 && $0.1 == 2 })   // Ctrl+T
        XCTAssertTrue(shipped.contains { $0.0 == 23 && $0.1 == 2 })   // Ctrl+W
        XCTAssertTrue(shipped.contains { $0.0 == 43 && $0.1 == 2 })   // Ctrl+Tab
        XCTAssertTrue(shipped.contains { $0.0 == 15 && $0.1 == 2 })   // Ctrl+R
    }

    /// Deliberately NOT shipped yet, and the test says so out loud so the
    /// omission is a decision rather than an oversight.
    func testPowerPointIsNotYetMapped() {
        XCTAssertNil(ContextProfiles.presentation.windowsActions,
                     "F5 / Shift+F5 need extended function-key support in keymap.rs, "
                     + "which is unverified. Re-add with a source.")
        XCTAssertEqual(ContextProfiles.profile(for: win("POWERPNT"), platform: .windows).id,
                       "console")
    }
}