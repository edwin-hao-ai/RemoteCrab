import XCTest
@testable import RemoteCrabCore

/// A profile is executable input: it replays real key events into a
/// machine that already holds Accessibility permission. So loading one
/// has to be defensive in a specific way — a malformed file must cost
/// the user that file and nothing else, and the reason must be readable
/// rather than swallowed into a silent default.
final class ContextProfileStoreTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Decoding

    func testDecodesAValidProfile() throws {
        let json = """
        {"schemaVersion":1,"id":"demo","title":"Demo",
         "bundleIDs":["com.example.app"],
         "actions":[{"voiceHero":{"label":"Talk","symbol":"waveform"}}]}
        """
        let p = try ContextProfileStore.decode(data(json), from: "demo.json")
        XCTAssertEqual(p.id, "demo")
        XCTAssertEqual(p.bundleIDs, ["com.example.app"])
    }

    /// A file with no `schemaVersion` is the pre-versioning format. It
    /// must load with the default rather than being rejected — that is
    /// every suite anyone wrote before this change.
    func testAFileWithNoSchemaVersionStillLoads() throws {
        let json = """
        {"id":"legacy","title":"Legacy","bundleIDs":["com.example.app"],
         "actions":[{"voiceHero":{"label":"Talk","symbol":"waveform"}}]}
        """
        let p = try ContextProfileStore.decode(data(json), from: "legacy.json")
        XCTAssertEqual(p.schemaVersion, ContextProfile.currentSchemaVersion)
    }

    /// A file from a FUTURE app must be refused outright. Half-reading it
    /// is how a renamed field silently becomes a default.
    func testRejectsANewerSchemaVersionNamingBothVersions() {
        let json = """
        {"schemaVersion":9999,"id":"future","title":"Future","bundleIDs":[],"actions":[]}
        """
        XCTAssertThrowsError(try ContextProfileStore.decode(data(json), from: "f.json")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("9999"), "must name the version found: \(message)")
            XCTAssertTrue(message.contains("\(ContextProfile.currentSchemaVersion)"),
                          "must name the version supported: \(message)")
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try ContextProfileStore.decode(data("{"), from: "bad.json"))
    }

    func testRejectsAProfileWithNoId() {
        XCTAssertThrowsError(try ContextProfileStore.decode(
            data(#"{"title":"No id","bundleIDs":[],"actions":[]}"#), from: "x.json"))
    }

    // MARK: - Loading a directory's worth of files

    /// The important one: one broken file must not cost the user the
    /// good ones, and the failure must be attributable to a filename.
    func testABrokenFileDoesNotDiscardTheGoodOnes() {
        let result = ContextProfileStore.load([
            ("good.json", data(#"{"id":"good","title":"Good","bundleIDs":[],"actions":[]}"#)),
            ("bad.json", data("{")),
            ("alsoGood.json", data(#"{"id":"alsoGood","title":"Also","bundleIDs":[],"actions":[]}"#)),
        ])
        XCTAssertEqual(result.profiles.map(\.id).sorted(), ["alsoGood", "good"])
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertEqual(result.problems.first?.file, "bad.json")
        XCTAssertFalse(result.problems.first?.reason.isEmpty ?? true)
    }

    /// Whatever came off disk is a user file by definition — the store
    /// stamps the source so the sheet can show it and so precedence works.
    func testLoadedProfilesAreStampedAsUserFiles() {
        let result = ContextProfileStore.load([
            ("a.json", data(#"{"id":"a","title":"A","bundleIDs":[],"actions":[]}"#))])
        XCTAssertEqual(result.profiles.first?.source, .userFile)
    }

    func testNoFilesIsNotAnError() {
        let result = ContextProfileStore.load([])
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
    }

    // MARK: - Merge order

    func testUserFileOutranksRemoteWhichOutranksBuiltin() {
        let b = ContextProfile(id: "x", title: "builtin", actions: [])
        let r = ContextProfile(id: "x", title: "remote", source: .remote, actions: [])
        let u = ContextProfile(id: "x", title: "user", source: .userFile, actions: [])
        for (user, remote, expected) in [([u], [r], "user"), ([], [r], "remote"), ([], [], "builtin")] {
            let merged = ContextProfileStore.merge(builtin: [b], user: user, remote: remote)
            XCTAssertEqual(merged.map(\.title), [expected])
        }
    }

    func testAnOverrideReplacesRatherThanDuplicates() {
        let b = ContextProfile(id: "x", title: "builtin", actions: [])
        let u = ContextProfile(id: "x", title: "user", source: .userFile, actions: [])
        XCTAssertEqual(ContextProfileStore.merge(builtin: [b], user: [u], remote: []).count, 1)
    }

    /// An override has to still MATCH, or installing it silently does
    /// nothing — which is what the old first-match-wins lookup caused.
    func testAnOverrideStillMatchesItsApps() {
        let b = ContextProfile(id: "agent", title: "Agent",
                               bundleIDs: ["com.apple.Terminal"],
                               actions: [.voiceHero(label: "T", symbol: "waveform")])
        let u = ContextProfile(id: "agent", title: "Mine", source: .userFile,
                               bundleIDs: ["com.example.terminal"],
                               actions: [.voiceHero(label: "T", symbol: "waveform")])
        let merged = ContextProfileStore.merge(builtin: [b], user: [u], remote: [])
        let app = IBAppInfo(id: "com.example.terminal", name: "Term", pid: 1,
                            isActive: true, iconPNG: nil)
        XCTAssertEqual(ContextProfiles.profile(for: app, platform: .mac, in: merged).title, "Mine")
        // And the built-in's own app no longer resolves, since the
        // override replaced it wholesale rather than merging.
        let old = IBAppInfo(id: "com.apple.Terminal", name: "Term", pid: 1,
                            isActive: true, iconPNG: nil)
        XCTAssertEqual(ContextProfiles.profile(for: old, platform: .mac, in: merged).id, "console")
    }
}