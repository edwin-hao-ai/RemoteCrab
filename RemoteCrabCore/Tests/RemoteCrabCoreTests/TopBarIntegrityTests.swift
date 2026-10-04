import XCTest

/// Guards the iOS top bar against silent deletions.
///
/// This exists because of a real accident: a text-slicing edit meant to
/// replace ONE button's block matched a `.frame(width: 44, height: 44)` line
/// belonging to a LATER button, so the "replacement" spanned the mirror menu
/// and the overflow menu and deleted both. **It compiled.** Tests passed. The
/// only thing that noticed was a person looking at their phone.
///
/// So the assertion is deliberately crude and source-level: every top-bar
/// action must still be present in `ContentView.swift`. It cannot tell a
/// button is wired correctly, and it is not trying to — it only catches the
/// failure mode that a compiler cannot, which is code that stopped existing.
final class TopBarIntegrityTests: XCTestCase {

    /// Path-independent lookup: the app target's sources sit next to this
    /// package's test bundle in the repo, so walk up to the repo root rather
    /// than hard-coding a runner-relative path.
    private static var contentViewURL: URL {
        // Start from the DIRECTORY: walking up from the file path itself
        // makes the first candidate `<file>.swift/../..`, which never resolves.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("RemoteCrabCapture/ContentView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.appendingPathComponent("..")
        }
        return dir.appendingPathComponent("RemoteCrabCapture/ContentView.swift")
    }

    private var source: String {
        (try? String(contentsOf: Self.contentViewURL, encoding: .utf8)) ?? ""
    }

    /// Each of these is a control the user can see and use. Losing one is
    /// invisible to the compiler and to every behavioural test, so it gets
    /// its own line here.
    private let requiredTopBarActions: [String] = [
        // status pill (connection state)
        "showConnectionSheet = true",
        // app switcher
        "showAppSwitcher = true",
        // camera
        "engine.setCameraEnabled(",
        // audio: microphone AND speaker are two entries in one dropdown
        "engine.toggleMicrophone()",
        "engine.toggleSpeaker()",
        // mirror + extended display share one dropdown
        "engine.toggleScreenMirror()",
        "engine.toggleExtendedDisplay()",
        // the overflow menu carries seven rows; a deletion here is exactly
        // what the accident above looked like
        "showMacPicker = true",
        "showSendDialog = true",
        "engine.sendClipboard()",
        "showNotifications = true",
        "showTrackpadGuide = true",
        "showSettings = true",
        "ellipsis.circle",
    ]

    func testEveryTopBarActionStillExists() {
        let text = source
        XCTAssertFalse(text.isEmpty, "could not read ContentView.swift at \(Self.contentViewURL.path)")
        for action in requiredTopBarActions {
            XCTAssertTrue(text.contains(action),
                          "top bar lost \(action) — a control the user can see disappeared, and the compiler will not tell you")
        }
    }

    /// The audio control is a MENU with two independent toggles, not a
    /// three-way picker. Collapsing them into one setting is a design
    /// regression that reads perfectly well and compiles perfectly well.
    func testAudioControlIsTwoTogglesInOneMenu() {
        let text = source
        XCTAssertTrue(text.contains("engine.toggleMicrophone()"))
        XCTAssertTrue(text.contains("engine.toggleSpeaker()"))
        XCTAssertFalse(text.contains("setAudioMode(.idle)"),
                       "the audio control must not offer a three-way Off/Microphone/Speaker picker — the two are independent features")
    }

    /// The mirror dropdown is TWO entries and must stay that way: the
    /// accident removed it entirely, and the extended-display row has a
    /// Windows gate that is easy to drop by accident.
    func testMirrorMenuKeepsBothEntries() {
        let text = source
        XCTAssertTrue(text.contains("IBLocale.Mirror.title"))
        XCTAssertTrue(text.contains("IBLocale.Mirror.extendDisplay"))
    }

    /// The top bar's buttons are 44 pt; the bottom row's are 48. Mixing them
    /// up is invisible in code review and visible on screen.
    func testTopBarButtonsStay44pt() {
        let text = source
        guard let topBarStart = text.range(of: "private var topBar: some View")?.lowerBound else {
            return XCTFail("could not locate topBar")
        }
        // End at the bottom row, not at the first helper: the keyboard
        // button in `pttRow` is 48 pt by design and sits between them, so a
        // wider window fails on a correct file.
        let topBarEnd = text.range(of: "private var pttRow")?.lowerBound ?? text.endIndex
        let body = String(text[topBarStart..<topBarEnd])
        XCTAssertFalse(body.contains(".frame(width: 48"), "top bar buttons are 44 pt")
    }
}