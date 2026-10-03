import XCTest
@testable import RemoteCrabCore

/// A profile is executable input: it replays real key events into a
/// machine that already holds Accessibility permission. So its format
/// has to be versioned and its origin has to be visible — and, because
/// every loader in this project swallows decode errors, adding a
/// non-optional field without a hand-written default would silently
/// wipe every suite a user had installed (rule 2).
final class ContextProfileFormatTests: XCTestCase {

    // MARK: - The previous on-disk format must still load

    /// Exactly the shape emitted before `schemaVersion` / `source` /
    /// the Windows slots existed. Every field must survive, and every
    /// new one must take its default instead of failing the decode.
    func testLoadsThePreviousFormatWithNothingLost() throws {
        let legacy = """
        {
          "id": "demo",
          "title": "Demo",
          "bundleIDs": ["com.example.app"],
          "actions": [
            {"key": {"keycode": 123, "label": "Go", "modifiers": 0, "symbol": "arrow.right"}},
            {"voiceHero": {"label": "Talk", "symbol": "waveform"}}
          ]
        }
        """.data(using: .utf8)!

        let p = try JSONDecoder().decode(ContextProfile.self, from: legacy)

        // Nothing that existed before is lost.
        XCTAssertEqual(p.id, "demo")
        XCTAssertEqual(p.title, "Demo")
        XCTAssertEqual(p.bundleIDs, ["com.example.app"])
        XCTAssertEqual(p.actions.count, 2)
        if case .key(_, _, let kc, _) = p.actions[0] { XCTAssertEqual(kc, 123) }
        else { XCTFail("action 0 lost its shape") }
        XCTAssertNotNil(p.voiceHero)

        // New fields default rather than aborting the decode.
        XCTAssertEqual(p.schemaVersion, ContextProfile.currentSchemaVersion)
        XCTAssertEqual(p.source, .builtin)
        XCTAssertNil(p.windowsProcessNames)
        XCTAssertNil(p.windowsActions)
    }

    /// The pre-versioning format also had profiles whose `actions` came
    /// through a marketplace, so an absent array must not throw either.
    func testLegacyProfileWithNoActionsArrayStillLoads() throws {
        let json = """
        {"id": "bare", "title": "Bare", "bundleIDs": []}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(ContextProfile.self, from: json)
        XCTAssertEqual(p.id, "bare")
        XCTAssertTrue(p.actions.isEmpty)
    }

    func testBuiltinProfilesAreVersionedAndSourced() {
        for p in ContextProfiles.all {
            XCTAssertEqual(p.schemaVersion, ContextProfile.currentSchemaVersion, p.id)
            XCTAssertEqual(p.source, .builtin, p.id)
        }
    }

    // MARK: - Round-trip

    /// The existing `testProfileCodableRoundTrip` depends on this: if
    /// the hand-written decoder and the synthesized encoder ever
    /// disagree about a new field, a suite silently changes on save.
    func testRoundTripKeepsEveryNewField() throws {
        let original = ContextProfile(
            id: "demo", title: "Demo",
            bundleIDs: ["com.example.app"],
            actions: [.voiceHero(label: "T", symbol: "waveform")],
            windowsProcessNames: ["WindowsTerminal", "cmd"],
            windowsActions: [.key(label: "Stop", symbol: "stop.fill", keycode: 53)])

        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ContextProfile.self, from: data)

        XCTAssertEqual(back, original)
        XCTAssertEqual(back.source, .builtin)
        XCTAssertEqual(back.windowsProcessNames, ["WindowsTerminal", "cmd"])
        XCTAssertEqual(back.windowsActions?.count, 1)
    }

    func testAUserFileProfileRoundTripsItsSource() throws {
        let original = ContextProfile(
            id: "demo", title: "Demo", source: .userFile,
            actions: [.voiceHero(label: "T", symbol: "waveform")])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ContextProfile.self, from: data).source, .userFile)
    }

    // MARK: - Sources are distinguishable

    /// `remote` exists as a declared seam for a signed feed. Nothing
    /// populates it yet, and it must not be mistakable for a suite the
    /// user chose to install.
    func testSourcesAreDistinct() {
        XCTAssertNotEqual(ProfileSource.builtin, ProfileSource.userFile)
        XCTAssertNotEqual(ProfileSource.builtin, ProfileSource.remote)
        XCTAssertNotEqual(ProfileSource.userFile, ProfileSource.remote)
        XCTAssertEqual(ProfileSource(rawValue: "userFile"), .userFile)
    }

    /// The label and the argument travel together, or not at all. The
    /// bug this replaces was a button labelled "Safari" that opened Bing
    /// because the label lived in the data and the argument in the view.
    func testASystemActionCanCarryItsOwnArgument() {
        let a = ContextAction.systemArg(label: "Browser", symbol: "safari.fill",
                                        command: .launchApp, argument: "https://example.com")
        guard case .systemArg(let label, _, let cmd, let arg) = a else {
            return XCTFail("systemArg must survive a round trip")
        }
        XCTAssertEqual(label, "Browser")
        XCTAssertEqual(cmd, .launchApp)
        XCTAssertEqual(arg, "https://example.com")

        let data = try? JSONEncoder().encode([a])
        let back = try? JSONDecoder().decode([ContextAction].self, from: data ?? Data())
        XCTAssertEqual(back?.first, a)
    }
}