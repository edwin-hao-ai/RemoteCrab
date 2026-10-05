import XCTest
@testable import RemoteCrabCore

/// The Mac menu bar must not lie about what it is showing.
///
/// Found from a screenshot of the shipping menu, in Chinese: the microphone
/// row was overlapped by a three-line English sentence about Screen Recording,
/// which belonged to the *speaker* row — and the speaker row was showing the
/// same sentence at the same time.
///
/// Four defects were stacked in that one picture:
///
/// 1. **The speaker's status was rendered twice** — once as the speaker row's
///    subtitle, and again as an `.overlay` on the *microphone* row.
/// 2. **The overlay could not affect layout**, so `.fixedSize(vertical: true)`
///    made the text escape the row and paint over its neighbours. An overlay is
///    the wrong tool for "this row needs to be taller".
/// 3. **The string was never localized.** `SystemAudioTapError.errorDescription`
///    returned Swift literals, so a Chinese menu rendered English — lesson 84's
///    shape, where the copy looks fine in the source and is wrong on screen.
/// 4. **A second bare literal** in `ReceiverSession` ("Not connected — the phone
///    cannot play audio…") for the same reason.
///
/// These are source-level assertions on purpose. The layout bug is invisible to
/// a unit test and obvious in a screenshot, and a screenshot is not a gate. So
/// the gate asserts the two things a screenshot cannot: that the text is
/// localized, and that it appears exactly once.
final class MacMenuCopyTests: XCTestCase {

    private static var repoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("RemoteCrabReceiver")
            if FileManager.default.fileExists(atPath: c.path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private func source(_ name: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("RemoteCrabReceiver/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The speaker's status is rendered once

    /// The bug, as an invariant. Two is the failure; one is the fix.
    ///
    /// A count rather than "the overlay is gone" on purpose: the day someone
    /// adds a third rendering of the same status somewhere else, this catches it
    /// too, and it does not care which row it lands on.
    func testTheSpeakersStatusIsRenderedExactlyOnceInTheMenu() throws {
        let menu = try source("MenuBarMenu.swift")
        let renderings = menu.components(separatedBy: "session.speakerStatus").count - 1
        XCTAssertEqual(renderings, 1,
                       """
                       \(renderings) places in MenuBarMenu.swift render the speaker's status. \
                       Each one draws the same words, and in the shipping menu two of them \
                       overlapped into an unreadable mess. One row owns this state: the one \
                       that reports it.
                       """)
    }

    /// Belt and braces on the specific mechanism: an overlay cannot change the
    /// parent's height, so any `fixedSize(vertical: true)` inside one will paint
    /// outside its row.
    func testNoOverlayInTheMenuUsesFixedSizeVertically() throws {
        let menu = try source("MenuBarMenu.swift")
        var offending: [String] = []
        var lines = menu.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains(".overlay(") {
            // Look ahead to the end of this overlay block.
            var j = i + 1
            while j < lines.count && !lines[j].contains("}") {
                if lines[j].contains("fixedSize(horizontal: false, vertical: true)") {
                    offending.append("line \(j + 1)")
                }
                j += 1
            }
        }
        XCTAssertTrue(offending.isEmpty,
                      """
                      fixedSize(vertical: true) inside an .overlay, at \(offending.joined(separator: ", ")).
                      An overlay does not participate in layout, so the text grows past its row and
                      lands on top of its neighbours. If a row needs to be taller, give it a taller
                      subtitle — do not float text over the row above.
                      """)
    }

    // MARK: - Nothing user-visible is a bare literal

    /// Every sentence the menu can show has to come from the catalog. This is
    /// the assertion that would have caught the English-in-a-Chinese-menu bug on
    /// its own, without anybody taking a screenshot.
    func testNoUserFacingLiteralInTheErrorDescriptions() throws {
        let tap = try source("SystemAudioTap.swift")
        var offending: [String] = []
        for (i, line) in tap.components(separatedBy: "\n").enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            // `return "…"` inside errorDescription is a user-facing literal.
            guard t.hasPrefix("return \"") else { continue }
            offending.append("SystemAudioTap.swift:\(i + 1)")
        }
        XCTAssertTrue(offending.isEmpty,
                      """
                      user-facing literals in an error description at \(offending.joined(separator: ", ")).
                      They render in whatever language the app is in, which in practice means English
                      inside a Chinese menu. Use IBLocale, and add the key to the catalog in both
                      languages — a key with only one translation is the same bug wearing a hat.
                      """)
    }

    /// The same trap, one file over: `speakerStatus = "…"` is the other way a
    /// status string reaches the menu without going through the catalog.
    func testSpeakerStatusIsNeverAssignedAnEnglishLiteral() throws {
        let session = try source("ReceiverSession.swift")
        var offending: [String] = []
        for (i, line) in session.components(separatedBy: "\n").enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("speakerStatus = \"") || t.contains("speakerStatus = (\"") else { continue }
            offending.append("ReceiverSession.swift:\(i + 1)")
        }
        XCTAssertTrue(offending.isEmpty,
                      """
                      a literal assigned straight into speakerStatus at \(offending.joined(separator: ", "))).
                      That string is drawn in the menu bar, so it belongs in the catalog.
                      """)
    }

    /// And the positive check: the strings these paths return must actually
    /// EXIST in the catalog, in both languages. A key that is referenced but
    /// missing renders as the raw key — which looks like a bug and reads like a
    /// typo.
    func testEverySpeakerStringTheMenuUsesExistsInBothLanguages() throws {
        let catalog = try XCTUnwrap(Self.catalog(), "Localizable.xcstrings not found")
        let menu = try source("MenuBarMenu.swift")
        let tap = try source("SystemAudioTap.swift")
        var referenced: Set<String> = []
        for src in [menu, tap] {
            for m in src.matches(of: "IBLocale\\.[A-Za-z0-9_]+\\.[A-Za-z0-9_]+") {
                referenced.insert(String(m))
            }
        }
        let sym2key = try Self.symbolToKey()
        var missing: [String] = []
        for sym in referenced.sorted() {
            guard let key = sym2key[sym] else { continue }
            guard let locs = catalog[key] else {
                missing.append("\(sym) → “\(key)” is not in the catalog")
                continue
            }
            for required in ["en", "zh-Hans"] where locs[required] == nil {
                missing.append("\(sym) → “\(key)” has no \(required) translation")
            }
        }
        XCTAssertTrue(missing.isEmpty, "menu strings not fully localized:\n  \(missing.joined(separator: "\n  "))")
    }

    // MARK: - Fixtures

    private static func catalog() -> [String: [String: String]]? {
        let url = repoRoot
            .appendingPathComponent("RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else { return nil }
        var out: [String: [String: String]] = [:]
        for (key, entry) in strings {
            guard let locs = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
            var byLoc: [String: String] = [:]
            for (loc, unit) in locs {
                if let v = (unit as? [String: Any])?["stringUnit"] as? [String: Any],
                   let s = v["value"] as? String { byLoc[loc] = s }
            }
            out[key] = byLoc
        }
        return out
    }

    private static func symbolToKey() throws -> [String: String] {
        let url = repoRoot.appendingPathComponent(
            "RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var map: [String: String] = [:]
        var depth = 0
        var stack: [(name: String, base: Int)] = []
        func delta(_ l: String) -> Int {
            l.reduce(0) { $1 == "{" ? $0 + 1 : ($1 == "}" ? $0 - 1 : $0) }
        }
        func keyLiteral(in l: String) -> String? {
            guard let open = l.range(of: "IBL(\"") else { return nil }
            let rest = String(l[open.upperBound...])
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("public enum ") {
                let tail = line.dropFirst("public enum ".count)
                stack.append((String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }), depth))
                depth += delta(line)
                continue
            }
            depth += delta(line)
            while let top = stack.last, depth <= top.base { stack.removeLast() }
            guard let enumName = stack.last?.name else { continue }
            if line.hasPrefix("public static func ") {
                let head = line.dropFirst("public static func ".count)
                let name = String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                if let k = keyLiteral(in: line) {
                    map["IBLocale.\(enumName).\(name)"] = k
                } else {
                    for j in (i + 1)..<min(i + 6, lines.count) {
                        if let k = keyLiteral(in: lines[j]) { map["IBLocale.\(enumName).\(name)"] = k; break }
                    }
                }
                continue
            }
            guard line.hasPrefix("public static let "), let k = keyLiteral(in: line) else { continue }
            let head = line.dropFirst("public static let ".count)
            let name = String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            map["IBLocale.\(enumName).\(name)"] = k
        }
        return map
    }
}

private extension String {
    /// Small regex helper so the test does not drag in a dependency for two
    /// patterns.
    func matches(of pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return re.matches(in: self, options: [], range: range).compactMap { m in
            Range(m.range, in: self).map { String(self[$0]) }
        }
    }
}
