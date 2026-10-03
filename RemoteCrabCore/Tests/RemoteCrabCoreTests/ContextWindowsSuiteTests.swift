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

    // MARK: - What the sheet actually renders

    private func named(_ name: String) -> IBAppInfo {
        IBAppInfo(id: "pid:1", name: name, pid: 1, isActive: true, iconPNG: nil)
    }

    /// The load-bearing regression test for the whole change: a matched
    /// suite on Windows must render its OWN actions. Before this the view
    /// read `profile.gridActions` unconditionally, so a Windows suite
    /// that matched still showed the Mac shortcuts.
    func testAMatchedWindowsSuiteRendersItsOwnActions() {
        let macKeys = ContextProfiles.appActions(for: ContextProfiles.editor, platform: .mac)
        let winKeys = ContextProfiles.appActions(for: ContextProfiles.editor, platform: .windows)
        XCTAssertEqual(macKeys.count, 6)
        XCTAssertEqual(winKeys.count, 6)
        XCTAssertNotEqual(macKeys, winKeys, "Windows must not render the Mac action set")
        XCTAssertTrue(macKeys.contains { action in
            if case .key(_, _, _, let m) = action { return m & 8 != 0 }
            return false
        }, "the Mac set is \u{2318}-based")
        XCTAssertFalse(winKeys.contains { action in
            if case .key(_, _, _, let m) = action { return m & 8 != 0 }
            return false
        }, "no Windows action may carry the \u{2318} bit")
    }

    /// A Mac-only suite on Windows renders an empty app section rather
    /// than the Mac keys \u{2014} and the always-on system grid stays.
    func testAMacOnlySuiteRendersNothingOnWindows() {
        let p = ContextProfiles.profile(for: named("Keynote"), platform: .windows)
        XCTAssertEqual(ContextProfiles.appActions(for: p, platform: .windows), [])
        XCTAssertFalse(ContextProfiles.systemActions(for: .windows).isEmpty)
    }

    func testTheConsoleNeverRendersItsKeysTwice() {
        for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
            XCTAssertEqual(ContextProfiles.appActions(for: ContextProfiles.console,
                                                      platform: platform), [], "\(platform)")
        }
    }

    /// `opencode` has no verified Windows mapping, so on a PC it must not
    /// render its own Mac hero — but it still gets ONE, because voice is
    /// the button that works on every platform and the system grid below
    /// it renders unconditionally. So the fallback is the console hero, and
    /// the invariant is "not its own Mac set", not "nothing".
    func testVoiceHeroIsPerPlatformToo() {
        XCTAssertNotNil(ContextProfiles.voiceHero(for: ContextProfiles.agent, platform: .mac))
        XCTAssertNotNil(ContextProfiles.voiceHero(for: ContextProfiles.agent, platform: .windows))
        let opencodeWindows = ContextProfiles.voiceHero(for: ContextProfiles.opencode, platform: .windows)
        let opencodeMac = ContextProfiles.voiceHero(for: ContextProfiles.opencode, platform: .mac)
        XCTAssertNotEqual(opencodeWindows, opencodeMac,
                          "opencode must not borrow its Mac-only hero on Windows")
        XCTAssertNotNil(opencodeWindows, "voice is never withheld")
        XCTAssertEqual(ContextProfiles.appActions(for: ContextProfiles.opencode, platform: .windows), [])
    }

    // MARK: - The Windows system grid
    //
    // `windowsSystemActions` is a standalone array, NOT a profile's
    // `windowsActions`, so every `for profile in ContextProfiles.all`
    // loop above silently skipped it — and `systemActions(for:)` renders
    // it unconditionally. These are the tests it never had.

    /// No platform's always-rendered system grid may carry a voice hero.
    ///
    /// The hero is a full-width capsule; in a two-column grid cell it is
    /// the wrong shape, and `ContextSheetView` draws the hero above the
    /// grid from `voiceHero(for:platform:)`. The Mac side was already
    /// safe because `console.gridActions` filters it. Windows shipped the
    /// hero *inside* the grid, so a matched suite rendered "Talk to
    /// Computer" twice.
    func testTheSystemGridNeverCarriesTheVoiceHero() {
        for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
            for action in ContextProfiles.systemActions(for: platform) {
                if case .voiceHero = action {
                    XCTFail("\(platform): the system grid must not render a second voice hero")
                }
            }
        }
    }

    /// The companion invariant: filtering the hero must not COST the user
    /// one. A suite with no verified Windows mapping has no
    /// `windowsActions`, so before the fallback it got no hero at all once
    /// the grid stopped carrying one. Voice is the one button that works
    /// everywhere, so it is never withheld.
    func testEveryWindowsPeerGetsExactlyOneVoiceHero() {
        let profiles = ContextProfiles.all + [ContextProfiles.console]
        for profile in profiles {
            for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
                XCTAssertNotNil(ContextProfiles.voiceHero(for: profile, platform: platform),
                                "\(profile.id)/\(platform): no voice hero")
                let inGrid = ContextProfiles.systemActions(for: platform)
                    .filter { if case .voiceHero = $0 { return true }; return false }
                XCTAssertTrue(inGrid.isEmpty, "\(profile.id)/\(platform): hero duplicated in the grid")
            }
        }
    }

    /// Every key action in the system grid must name a key it means.
    ///
    /// "Show Desktop" was authored as ⊞⌥D and sent keycode **53**, which
    /// is Escape — `keymap.rs:105` maps 0x35 to `vk::ESCAPE` — so the
    /// button did nothing at all. It now rides the same `showDesktop`
    /// system command the switcher's Desktop card uses, which Windows
    /// implements as a real minimise-all.
    func testTheWindowsSystemGridSendsNoMislabelledShortcut() {
        let system = ContextProfiles.systemActions(for: .windows)
        for action in system {
            guard case .key(let label, _, let kc, _) = action else { continue }
            XCTAssertNotEqual(kc, 53,
                              "\(label): keycode 53 is Escape, not the key this label names")
            XCTAssertNotEqual(kc, 50,
                              "\(label): keycode 50 is the macOS grave accent")
        }
        // Show Desktop must be the command, not a synthesised chord.
        XCTAssertTrue(system.contains { action in
            if case .system(let label, _, let command) = action {
                return label == "Show Desktop" && command == .showDesktop
            }
            return false
        }, "Show Desktop should ride IBSystemCommand.showDesktop")
    }

    /// A Windows user must never be shown an Apple-only glyph.
    ///
    /// `safari.fill` on the "Browser" button and `macwindow.on.rectangle`
    /// on "Show Desktop" both shipped: the buttons worked (or didn't) but
    /// the icons said "Mac", which is the whole "Windows has no Safari"
    /// complaint. There is no Edge in SF Symbols and no reason to fake
    /// one — `globe` describes what the button does.
    func testTheWindowsSystemGridUsesNoAppleOnlySymbols() {
        let banned = ["safari", "macwindow", "command.", "rectangle.3.group",
                      "square.on.square", "dock.rectangle"]
        for action in ContextProfiles.windowsSystemActions {
            let symbol: String
            switch action {
            case .key(_, let s, _, _), .system(_, let s, _),
                 .systemArg(_, let s, _, _), .voiceHero(_, let s):
                symbol = s
            }
            for needle in banned {
                XCTAssertFalse(symbol.contains(needle),
                               "Windows system action uses the Apple-only symbol \(symbol)")
            }
        }
    }

    /// Seven grid cells, so the last row has one empty half. That gap is
    /// deliberate and must not be "filled" the way the per-suite even-count
    /// rule would suggest: a button here is either a receiver command that
    /// verifiably works or a documented keybinding, and there is no
    /// eighth honest Windows system control — brightness is the Mac's
    /// eighth and tenth and is absent on purpose.
    func testTheWindowsSystemGridIsSevenVerifiedActions() {
        let grid = ContextProfiles.systemActions(for: .windows)
        XCTAssertEqual(grid.count, 7)
        let labels = grid.compactMap { action -> String? in
            switch action {
            case .key(let l, _, _, _), .system(let l, _, _), .systemArg(let l, _, _, _):
                return l
            case .voiceHero:
                return nil
            }
        }
        XCTAssertEqual(Set(labels), ["Volume Up", "Volume Down", "Mute",
                                     "Play / Pause", "Lock Screen",
                                     "Show Desktop", "Browser"])
    }
}
