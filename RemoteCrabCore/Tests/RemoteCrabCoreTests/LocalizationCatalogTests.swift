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
}
