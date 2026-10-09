import XCTest

/// Session-scoped text must not name a Mac while the session is with a PC.
///
/// ## Why this is not the test that was here
///
/// `testNoSessionSurfaceNamesAMac` listed **26 keys**. All 26 were already
/// clean, so it passed — and it caught nothing, ever: it was coverage *by
/// example*, written after the fixes rather than derived from the surfaces. A
/// key added to a session surface afterwards sails straight past it. Measured
/// against this repo's own catalog: of the keys whose shipped text names a Mac,
/// that list covered **0**.
///
/// This one walks the surfaces instead. Each file that renders during a session
/// is listed once; every `IBLocale.<Enum>.<symbol>` referenced from those files
/// is resolved through `IBLocale.swift` to its catalog key, and every
/// localization of that key is checked. Adding a string to a known surface is
/// covered on the next run with no edit here.
///
/// ## The two halves
///
/// `deliberateMacText` is the other half, and it matters more than the scan.
/// Product-level copy — onboarding, permission explanations, "Download for
/// Mac" — legitimately says Mac, because RemoteCrab's Mac app is a real thing
/// the user installs and grants OS permissions to. Leaving that unsaid is how
/// the next person "helpfully" fixes it. Each entry carries a reason so the
/// omission reads as a decision rather than an oversight, the same move as
/// `testPowerPointIsNotYetMapped`.
final class SessionSurfaceCopyTests: XCTestCase {

    // MARK: - Fixtures

    private static var repoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("RemoteCrabCapture")
            if FileManager.default.fileExists(atPath: c.path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private var catalog: [String: [String: String]] {
        get throws {
            let url = Self.repoRoot
                .appendingPathComponent("RemoteCrabCore/Sources/RemoteCrabCore/Resources/Localizable.xcstrings")
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let strings = try XCTUnwrap(root?["strings"] as? [String: Any])
            var out: [String: [String: String]] = [:]
            for (key, entry) in strings {
                guard let locs = (entry as? [String: Any])?["localizations"] as? [String: Any] else { continue }
                var byLoc: [String: String] = [:]
                for (loc, unit) in locs {
                    let v = (unit as? [String: Any])?["stringUnit"] as? [String: Any]
                    if let s = v?["value"] as? String { byLoc[loc] = s }
                }
                out[key] = byLoc
            }
            return out
        }
    }

    /// The catalog key an `IBL("…")` literal declares, if this line has one.
    private static func keyLiteral(in line: String) -> String? {
        guard let open = line.range(of: "IBL(\"") else { return nil }
        let rest = String(line[open.upperBound...])
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    /// `IBLocale.<Enum>.<symbol>` → catalog key.
    ///
    /// Parsed rather than hand-listed, so renaming a symbol in `IBLocale.swift`
    /// cannot silently make this test scan nothing. Two declaration shapes
    /// exist and both are handled — the second spans lines, with the key in its
    /// body rather than at the declaration:
    ///
    ///     public static let name = IBL("Key")
    ///     public static func name(_ x: String) -> String { String(format: IBL("Key"), x) }
    private func symbolToKey() throws -> [String: String] {
        let url = Self.repoRoot.appendingPathComponent(
            "RemoteCrabCore/Sources/RemoteCrabCore/DesignSystem/IBLocale.swift")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var map: [String: String] = [:]
        // A stack plus brace depth, because `IBLocale.Pairing` contains a nested
        // `Attempt` enum. Two mistakes live here and both were made:
        //   * a single name never leaves the nest, so every declaration after it
        //     resolves under the wrong name (`Pairing.seenComputers`);
        //   * popping on ANY `}` empties the stack inside the first function body
        //     (376 symbols parsed instead of 511).
        // Depth is what distinguishes "an enum's body closed" from "a function's
        // body closed".
        var depth = 0
        var enumStack: [(name: String, base: Int)] = []
        func delta(_ line: String) -> Int {
            line.reduce(0) { $1 == "{" ? $0 + 1 : ($1 == "}" ? $0 - 1 : $0) }
        }

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("public enum ") {
                let tail = line.dropFirst("public enum ".count)
                enumStack.append((String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }), depth))
                depth += delta(line)
                continue
            }
            depth += delta(line)
            while let top = enumStack.last, depth <= top.base { enumStack.removeLast() }
            guard let enumName = enumStack.last?.name else { continue }

            // The two-line form: the key sits in the body, so look ahead a few
            // lines rather than carrying state that a body which never closes
            // cleanly would leak into the declarations after it.
            if line.hasPrefix("public static func ") {
                let head = line.dropFirst("public static func ".count)
                let name = String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                if let k = Self.keyLiteral(in: line) {
                    map["IBLocale.\(enumName).\(name)"] = k
                } else {
                    for j in (i + 1)..<min(i + 6, lines.count) {
                        if let k = Self.keyLiteral(in: lines[j]) {
                            map["IBLocale.\(enumName).\(name)"] = k
                            break
                        }
                    }
                }
                continue
            }

            guard line.hasPrefix("public static let "),
                  let k = Self.keyLiteral(in: line) else { continue }
            let head = line.dropFirst("public static let ".count)
            let name = String(head.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            map["IBLocale.\(enumName).\(name)"] = k
        }
        return map
    }

    /// Files that render while a session is up. Listing a *file* rather than a
    /// key is the point: a new string in one of these is covered next run with
    /// no edit here.
    private static let sessionSurfaces = [
        "ContentView.swift",
        "ContextSheetView.swift",
        "AppSwitcherView.swift",
        "InstalledAppsView.swift",
        "ComputerPickerView.swift",
        "KeyboardScreen.swift",
        "TouchpadScreen.swift",
        "ScreenShareView.swift",
        "NotificationListView.swift",
        "CaptureEngine.swift",
    ]

    /// Deliberately NOT session surfaces, and why. Listed so their absence reads
    /// as a decision:
    ///
    /// * `OnboardingFlow`, `PermissionFlow` — read before any computer exists.
    /// * `IOSSettingsView` — the deliberate Mac copy lives here (`downloadMac`).
    /// * `TrackpadGuideView` — a reference the user opens *during* a session, so
    ///   it is platform-split per platform rather than Mac-free; see lesson 115.
    private static let notSessionSurfaces = [
        "OnboardingFlow.swift", "PermissionFlow.swift", "IOSSettingsView.swift",
        "TrackpadGuideView.swift",
    ]

    /// Copy that may say "Mac", each with why. See the type comment.
    private static let deliberateMacText: [(key: String, why: String)] = [
        ("RemoteCrab turns your iPhone into a camera, microphone, trackpad and keyboard for this Mac. This short setup grants what macOS needs.",
         "onboarding: the Mac app is a real product the user installs and grants OS permissions to"),
        ("RemoteCrab drives your Mac's cursor and keyboard from your iPhone — macOS requires the Accessibility permission for that. This step can't be skipped: without it, the trackpad and keyboard don't work.",
         "permission explanation: the grant being requested is macOS's, and 'the computer' would make the Settings pane unfindable"),
        ("RemoteCrab installs a small camera extension so FaceTime, Zoom, Photo Booth, OBS and other apps can select “RemoteCrab Camera”. macOS asks you to approve it once.",
         "camera-extension onboarding: names the macOS approval dialog the user is about to see"),
        ("Click “Enable Camera Extension” below — macOS will ask you to approve the extension once.",
         "the same dialog, shorter form"),
        ("A small camera extension lets FaceTime, Zoom, Photo Booth and other apps select “RemoteCrab Camera”. macOS asks you to approve it once, then turn it on.",
         "the same dialog, Permissions-flow form"),
        ("We need Screen Recording to mirror a Mac window to your iPhone. macOS adds RemoteCrab to the list when you tap the button — switch it on, then restart RemoteCrab.",
         "Screen Recording is a macOS-only permission; 'the computer' would be a category error"),
        ("macOS caches this permission per running app — if you already turned it on but the status won't update, restart RemoteCrab once and it will be detected.",
         "explains a macOS-specific caching behaviour the user would otherwise read as a bug"),
        ("Screen Recording is needed to play the Mac's audio on the iPhone. Use “Finish Setup…” above.",
         """
         Mac receiver's own menu bar, so "the Mac" is the accurate name — this app only ever runs on
         macOS. The rule this list exists to protect is the *opposite* one: the iPhone's copy says
         "computer", because a user reading it may be on Windows. Do not “fix” this one to match.
         """),
        ("This Mac did not provide an audio tap (error %d). Update macOS and try again.",
         "Mac receiver's own menu, and “this Mac” is the machine reporting on itself"),
        ("The audio tap could not be opened for reading (error %d). Reconnect or restart the Mac's audio and try again.",
         "Mac receiver's own menu — the audio being described is the Mac's own output"),
        ("Relay non-denylisted Mac notification banners to your iPhone",
         "the notification relay only exists on macOS; it sends nothing on Windows, so this names the mechanism it is for"),
        ("Your Mac needs Accessibility permission to control apps.",
         "Accessibility is a macOS permission; 'your computer needs' names nothing the user can act on"),
        ("Optional — needed only to mirror a Mac window to your iPhone.",
         "Screen Recording explanation; macOS-only capability, same reasoning as the longer form"),
        // The Mac half of the platform-split trackpad guide (lesson 115). These
        // keys exist precisely BECAUSE the guide selects by platform — a Mac
        // peer must be told about ⌃⌥⌘⇧ and Mission Control. Their Windows
        // counterparts are separate keys, and removing these would leave the Mac
        // user with the Windows wording.
        ("Trackpad guide: drag to move the cursor; tap to click; two fingers scroll, tap for right-click, pinch to zoom; hold or double-tap and hold to drag; three-finger tap for middle-click; three or four fingers to switch; lock ⌃⌥⌘⇧ to combine them, and ⇧ to select a range.",
         "Mac branch of the platform-split gesture guide"),
        ("Two fingers up or down to scroll the Mac", "Mac branch of the gesture guide"),
        ("Keep one finger down and move to drag on the Mac", "Mac branch of the gesture guide"),
        ("Pinch to zoom the app on the Mac — it acts as ⌘ + scroll, so it zooms whatever the front app zooms",
         "Mac branch of the gesture guide"),
        ("Pinch to zoom", "Mac branch of the gesture guide"),
    ]

    private static let macPattern = try! NSRegularExpression(
        pattern: "\\bMac\\b|\\bmacOS\\b|在 Mac|Mac 上|Mac 的|Mac app",
        options: [])

    private func mentionsMac(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..<s.endIndex, in: s)
        return Self.macPattern.firstMatch(in: s, options: [], range: r) != nil
    }

    // MARK: - The scan

    /// Every session surface's strings are Mac-free, in every localization.
    func testNoSessionSurfaceStringNamesAMac() throws {
        let cat = try catalog
        let deliberate = Set(Self.deliberateMacText.map(\.key))
        let sym2key = try symbolToKey()
        XCTAssertGreaterThan(sym2key.count, 400,
                             "only \(sym2key.count) IBL symbols parsed — the parser regressed and this test is scanning almost nothing")

        let refPattern = try! NSRegularExpression(pattern: "IBLocale\\.[A-Za-z0-9_]+\\.[a-z][A-Za-z0-9_]*")
        var scanned = 0
        var leaks: [String] = []
        for file in Self.sessionSurfaces {
            let path = Self.repoRoot.appendingPathComponent("RemoteCrabCapture/\(file)")
            guard let src = try? String(contentsOf: path, encoding: .utf8) else {
                XCTFail("session surface \(file) is not in RemoteCrabCapture/ — update sessionSurfaces")
                continue
            }
            let full = NSRange(src.startIndex..<src.endIndex, in: src)
            for m in refPattern.matches(in: src, options: [], range: full) {
                guard let r = Range(m.range, in: src) else { continue }
                let sym = String(src[r])
                guard let key = sym2key[sym] else {
                    // Uppercase-leading segments are types and cases
                    // (`IBLocale.Pairing.Attempt`); the pattern already excludes
                    // those, so an unresolved lowercase symbol is a real gap.
                    XCTFail("\(sym) (in \(file)) has no catalog key — the IBL parser missed it")
                    continue
                }
                scanned += 1
                // A deliberate key can still be *rendered* from a session
                // surface (the overflow menu's "Download for Mac"), and the
                // exemption is a decision about the copy, not about where it is
                // rendered. Skipping it here keeps the two assertions separate:
                // `testTheOnlyMacTextIsDeliberate` is what holds it to a reason.
                if deliberate.contains(key) { continue }
                for (loc, value) in cat[key] ?? [:] where mentionsMac(value) {
                    leaks.append("\(file) → \(sym) → \(key) [\(loc)]")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 40,
                             "only \(scanned) session strings scanned — a surface or pattern change has narrowed coverage")
        XCTAssertTrue(leaks.isEmpty, "session text names a Mac:\n  \(leaks.joined(separator: "\n  "))")
    }

    // MARK: - The other half: naming the deliberate omissions

    /// Each exemption still exists and still says Mac. If the copy is reworded
    /// to "computer" the exemption must be dropped, not left to rot.
    func testEveryDeliberateMacTextStillExistsAndStillSaysMac() throws {
        let cat = try catalog
        for entry in Self.deliberateMacText {
            let values = try XCTUnwrap(cat[entry.key],
                                       "deliberate Mac copy was deleted: \(entry.key) — drop the entry or write a new one")
            XCTAssertTrue(values.values.contains { mentionsMac($0) },
                          "\(entry.key) no longer says Mac anywhere — remove it from deliberateMacText. Why it said Mac: \(entry.why)")
        }
    }

    /// And the inverse: every Mac-mentioning key in the catalog must be an
    /// accounted-for exemption. This is what turns "the 26-key list" into "the
    /// list of everything", and it is the assertion that would have caught the
    /// four half-migrated strings (zh-Hans already said 电脑, the en value had
    /// not been touched) without anyone grepping for them.
    func testTheOnlyMacTextIsDeliberate() throws {
        let cat = try catalog
        let exempt = Set(Self.deliberateMacText.map(\.key))
        var unaccounted: [String] = []
        for (key, locs) in cat where locs.values.contains(where: { mentionsMac($0) }) {
            if !exempt.contains(key) { unaccounted.append(key) }
        }
        XCTAssertTrue(unaccounted.isEmpty, """
            catalog keys whose shipped text names a Mac, with no stated reason:
            \(unaccounted.map { "  • \($0)" }.joined(separator: "\n"))
            Either the copy is wrong, or it is deliberate and needs an entry in
            deliberateMacText with a reason.
            """)
    }
}
