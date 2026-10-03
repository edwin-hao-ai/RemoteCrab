import XCTest
@testable import RemoteCrabCore

/// Guards the String Catalog: every key a new feature adds must ship
/// both an `en` source unit and a `zh-Hans` translation. Xcode's build
/// only warns about a missing translation, so a forgotten one silently
/// renders English in a Chinese UI — this test fails the build instead.
final class LocalizationCatalogTests: XCTestCase {

    /// Loads the `strings` table from `Localizable.xcstrings`.
    ///
    /// SwiftPM compiles `.xcstrings` into `.lproj/Localizable.strings`
    /// inside the built bundle, so the raw JSON is usually NOT present as
    /// a bundle resource. Try the bundle first (works if it was copied
    /// verbatim), then fall back to the source file located relative to
    /// this test (`#filePath`), which is always the source of truth.
    private func catalog() throws -> [String: Any] {
        let data: Data
        if let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings") {
            data = try Data(contentsOf: url)
        } else {
            let sourceURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // RemoteCrabCoreTests/
                .deletingLastPathComponent()   // Tests/
                .deletingLastPathComponent()   // RemoteCrabCore/
                .appendingPathComponent("Sources/RemoteCrabCore/Resources/Localizable.xcstrings")
            data = try Data(contentsOf: sourceURL)
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    func testUpdateKeysAreBilingual() throws {
        // Use the literal English source strings as catalog keys, NOT the
        // `IBLocale.Update.*` resolved values: `IBL()` resolves against the
        // current locale, so on a non-English locale (or a toolchain that
        // compiles the catalog into `.lproj/*.strings`) those values would
        // be translated and the lookup would miss. The catalog key IS the
        // English source string.
        let keys = [
            "Check for Updates…",
            "Restart to Update",
            "Automatically check for updates",
            "Download and install new versions in the background.",
        ]
        let strings = try catalog()
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "no localizations: \(key)")
            XCTAssertNotNil(locs["en"], "missing en: \(key)")
            XCTAssertNotNil(locs["zh-Hans"], "missing zh-Hans: \(key)")
        }
    }

    /// Every context-mode action label must ship a `zh-Hans` translation.
    ///
    /// The labels are *data* (`ContextProfiles`), so they cannot be `IBL(...)`
    /// at the call site; they render through `IBLocale.string(_:)`. That
    /// indirection already hid one real bug — the sheet used
    /// `Text(LocalizedStringKey(label))`, which resolves against
    /// `Bundle.main`, and the catalog lives in this package, so the lookup
    /// silently fell back to the English key *even though every translation
    /// existed*. Deriving the keys from the registry (rather than a hardcoded
    /// list) means a new suite that forgets its translations fails here.
    ///
    /// Only `zh-Hans` is required: these entries carry no `en` unit by design
    /// (the key IS the English source).
    func testEveryContextActionLabelIsTranslated() throws {
        var labels = Set<String>()
        for profile in ContextProfiles.all {
            // `windowsActions` too: those labels render through the same
            // path, so a Windows suite that forgets its translations has
            // to fail here for the same reason a Mac one does.
            for action in profile.actions + (profile.windowsActions ?? []) {
                switch action {
                case .key(let label, _, _, _),
                     .system(let label, _, _),
                     .systemArg(let label, _, _, _),
                     .voiceHero(let label, _):
                    labels.insert(label)
                }
            }
        }
        // The system grid is NOT one of `all` — it is its own list per
        // platform — so it has to be walked explicitly or its labels ship
        // untranslated. That is how "Talk to Computer" would have reached
        // a Chinese user in English.
        for platform in [IBModifierBar.PeerPlatform.mac, .windows] {
            for action in ContextProfiles.systemActions(for: platform) {
                switch action {
                case .key(let label, _, _, _),
                     .system(let label, _, _),
                     .systemArg(let label, _, _, _),
                     .voiceHero(let label, _):
                    labels.insert(label)
                }
            }
            // The hero is no longer IN the grid (it is a full-width
            // capsule and rendering it twice was its own bug), so walking
            // the grid alone stopped covering its label — which is how
            // "Talk to Computer" would have quietly lost its zh-Hans.
            // Walk what the sheet actually draws: hero + app + system.
            for profile in ContextProfiles.all + [ContextProfiles.console] {
                guard case .voiceHero(let label, _) =
                        ContextProfiles.voiceHero(for: profile, platform: platform) else { continue }
                labels.insert(label)
            }
        }
        XCTAssertGreaterThan(labels.count, 50, "expected the full suite registry")

        let strings = try catalog()
        let missing = labels.sorted().filter { label in
            let entry = strings[label] as? [String: Any]
            let locs = entry?["localizations"] as? [String: Any]
            let zh = (locs?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
            return (zh?["value"] as? String)?.isEmpty != false
        }
        XCTAssertTrue(missing.isEmpty, "context labels with no zh-Hans translation: \(missing)")
    }

    /// Nothing reachable **inside a live session** may name a Mac.
    ///
    /// These surfaces are the ones a Windows user reads *while connected*,
    /// and the session is already platform-aware (⌘ vs ⊞, per-platform
    /// suites, a Windows launcher). Text that says "your Mac" in that same
    /// moment contradicts everything around it. Product-level copy —
    /// onboarding, permissions, "Download for Mac", the receiver itself —
    /// is deliberately NOT in this list: RemoteCrab's Mac app is a real
    /// thing users install, and rewriting that is a different decision.
    ///
    /// Asserted against the catalog **values**, not the keys: the keys
    /// still read "…on the Mac." because that is what `IBL()` looks up,
    /// while the `en` unit already reads "…on the computer." Asserting on
    /// keys would fail on correct copy, and asserting on `IBL(...)` would
    /// depend on the test host's locale.
    func testNoSessionSurfaceNamesAMac() throws {
        let keys = [
            // App switcher
            "No apps to switch to", "Switch to a running app on the Mac",
            "Desktop", "Show Desktop", "Open App…", "Refresh",
            "Pin", "Unpin", "Active", "Quit", "Force Quit", "Force Quit App?",
            "This immediately ends the app on the Mac. Unsaved changes will be lost.",
            "Showing app icons — allow Screen Recording on the Mac to see window previews.",
            // App launcher
            "Applications", "Search apps", "No apps listed yet",
            "Apps reported by the connected computer",
            "Asking your computer for its apps…",
            "Your computer didn’t answer",
            "Check that RemoteCrab Receiver is running and up to date, then try again.",
            "Reconnect, then try again.",
            // Context sheet + connection errors + mirror chrome
            "Buttons send keyboard or system events to your Mac",
            "Buttons send keyboard or system events to your computer",
            "Not connected to your Mac right now.",
            "App window mirror", "Follow frontmost app", "Computer",
        ]
        let strings = try catalog()
        var leaks: [String] = []
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any],
                                      "no localizations: \(key)")
            for (loc, unit) in locs {
                let value = ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                if value.contains("Mac") || value.contains("macOS") {
                    leaks.append("\(key) [\(loc)] -> \(value)")
                }
            }
        }
        XCTAssertTrue(leaks.isEmpty, "session text names a Mac: \(leaks)")
    }

    /// The launcher's waiting / no-answer states. They exist because the
    /// sheet used to say "No apps listed yet" while the Mac was still
    /// building the list, so a Chinese user would have read a *lie* in their
    /// own language — the new sentences must ship translated.
    func testLauncherWaitStatesAreBilingual() throws {
        let keys = [
            "Asking your computer for its apps…",
            "Your computer didn’t answer",
            "Check that RemoteCrab Receiver is running and up to date, then try again.",
            "Reconnect, then try again.",
        ]
        let strings = try catalog()
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "no localizations: \(key)")
            XCTAssertNotNil(locs["en"], "missing en: \(key)")
            XCTAssertNotNil(locs["zh-Hans"], "missing zh-Hans: \(key)")
        }
    }
}
