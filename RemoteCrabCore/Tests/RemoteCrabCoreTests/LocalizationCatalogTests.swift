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
