import XCTest
@testable import RemoteCrabCore

/// Tests for the multi-Mac pairing handshake: wire round-trips,
/// the pure ownership policy, and the persisted allow-list.
final class PairingTests: XCTestCase {

    // MARK: - Wire round-trip

    func testRoundTripClientHelloWithoutToken() throws {
        let hello = IBClientHello(name: "Edwin's MacBook Pro", id: "mac-1", appVersion: "0.2")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .clientHello)
        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]), hello)
    }

    func testRoundTripClientHelloWithToken() throws {
        let hello = IBClientHello(name: "Mac mini", id: "mac-2", token: "tok-abc", appVersion: "0.2")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]), hello)
        XCTAssertEqual(try IBWire.decodeClientHello(frames[0]).token, "tok-abc")
    }

    func testRoundTripSessionReplyEachResult() throws {
        for result in [IBSessionReplyResult.accepted, .pending, .busy, .denied] {
            let reply = IBSessionReply(result: result, ownerName: "Mac A", token: "tok")
            let encoded = try IBWire.encode(sessionReply: reply)
            let frames = IBWire.Parser().append(encoded)

            XCTAssertEqual(frames[0].kind, .sessionReply)
            XCTAssertEqual(try IBWire.decodeSessionReply(frames[0]), reply)
        }
    }

    // MARK: - Policy

    private func pairedMac(id: String = "mac-1", name: String = "Mac A", token: String = "tok") -> PairedMac {
        PairedMac(id: id, name: name, pairedAt: Date(timeIntervalSince1970: 0), token: token)
    }

    func testUnknownMacIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "New", id: "mac-9"),
            paired: [],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testPairedMacWithCorrectTokenIsAccepted() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok"),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .accept)
    }

    func testPairedMacWithWrongTokenIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Impostor", id: "mac-1", token: "wrong"),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testPairedMacWithoutTokenIsPending() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: nil),
            paired: [pairedMac()],
            owner: nil
        )
        XCTAssertEqual(decision, .pending)
    }

    func testOtherMacWhileOwnedIsBusy() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac B", id: "mac-2", token: "tok-b"),
            paired: [pairedMac(), pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")],
            owner: pairedMac()
        )
        XCTAssertEqual(decision, .busy(ownerName: "Mac A"))
    }

    func testOwnerReconnectWithTokenIsAccepted() {
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok"),
            paired: [pairedMac()],
            owner: pairedMac()
        )
        XCTAssertEqual(decision, .accept)
    }

    // MARK: - Policy (preferred Mac)

    func testPreferredMacWithTokenIsAccepted() {
        let macB = pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac B", id: "mac-2", token: "tok-b"),
            paired: [pairedMac(), macB],
            owner: nil,
            preferred: macB
        )
        XCTAssertEqual(decision, .accept)
    }

    func testOtherPairedMacWhilePreferredIsBusy() {
        let macB = pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok"),
            paired: [pairedMac(), macB],
            owner: nil,
            preferred: macB
        )
        XCTAssertEqual(decision, .busy(ownerName: "Mac B"))
    }

    func testUnknownMacWhilePreferredIsBusyNotPending() {
        let macB = pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Stranger", id: "mac-9"),
            paired: [pairedMac(), macB],
            owner: nil,
            preferred: macB
        )
        XCTAssertEqual(decision, .busy(ownerName: "Mac B"))
    }

    func testPreferredMacWithoutTokenStillGetsPrompt() {
        let macB = pairedMac(id: "mac-2", name: "Mac B", token: "tok-b")
        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac B", id: "mac-2", token: nil),
            paired: [pairedMac(), macB],
            owner: nil,
            preferred: macB
        )
        XCTAssertEqual(decision, .pending)
    }

    // MARK: - Store

    private func freshStore() -> MacPairingStore {
        let suite = "test.remotecrab.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return MacPairingStore(defaults: defaults)
    }

    func testPairMintsTokenAndPersists() {
        let suite = "test.remotecrab.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = MacPairingStore(defaults: defaults)
        let mac = store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        XCTAssertFalse(mac.token.isEmpty)
        XCTAssertEqual(store.paired.count, 1)

        // A second store over the same defaults sees the pairing.
        let reloaded = MacPairingStore(defaults: defaults)
        XCTAssertEqual(reloaded.paired, store.paired)
    }

    func testRePairKeepsTokenAndUpdatesName() {
        let store = freshStore()
        let first = store.pair(IBClientHello(name: "Old Name", id: "mac-1"))
        let second = store.pair(IBClientHello(name: "New Name", id: "mac-1"))

        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(store.paired.count, 1)
        XCTAssertEqual(store.paired[0].name, "New Name")
    }

    func testForgetAndRename() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        store.pair(IBClientHello(name: "Mac B", id: "mac-2"))

        store.rename(id: "mac-1", to: "Renamed")
        XCTAssertEqual(store.paired.first(where: { $0.id == "mac-1" })?.name, "Renamed")

        store.forget(id: "mac-1")
        XCTAssertEqual(store.paired.map(\.id), ["mac-2"])
    }

    // MARK: - Store (preferred Mac)

    func testPreferredPersistsAndExpires() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        XCTAssertNil(store.preferred)

        store.setPreferred(id: "mac-1")
        XCTAssertEqual(store.preferredId, "mac-1")
        XCTAssertEqual(store.preferred?.name, "Mac A")

        // Stale preference is treated as no preference.
        store.setPreferred(id: "mac-1", at: Date().addingTimeInterval(-MacPairingStore.preferredTTL - 1))
        XCTAssertNil(store.preferredId)
        XCTAssertNil(store.preferred)

        store.setPreferred(id: "mac-1")
        store.clearPreferred()
        XCTAssertNil(store.preferredId)
    }

    func testForgetClearsPreferenceForThatMac() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        store.setPreferred(id: "mac-1")
        store.forget(id: "mac-1")
        XCTAssertNil(store.preferredId)
    }

    /// The switch was silently reverting because of this. Picking a computer
    /// that has knocked but never been approved stored an id that resolved to
    /// `nil`, so `decide`'s hold-the-door branch never ran and the *other*
    /// computer took the session straight back.
    func testPreferredForAnUnpairedComputerStillHoldsTheDoor() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        store.setPreferred(id: "win-1", name: "DESKTOP")

        let preferred = store.preferred
        XCTAssertEqual(preferred?.id, "win-1")
        XCTAssertEqual(preferred?.name, "DESKTOP")
        // Never approved, so no token — which is why it is answered `pending`
        // and the user gets one approval card. Correct first-contact behaviour.
        XCTAssertEqual(preferred?.token, "")

        let decision = PairingPolicy.decide(
            hello: IBClientHello(name: "Mac A", id: "mac-1", token: "tok-a"),
            paired: store.paired,
            owner: nil,
            preferred: preferred
        )
        XCTAssertEqual(decision, .busy(ownerName: "DESKTOP"),
                       "the paired Mac must wait its turn, which is the whole point of choosing")
    }

    /// Backward compatibility: a preference written by an older build has an id
    /// but no name. It always named a *paired* Mac, so the first lookup still
    /// resolves it; only the never-paired case degrades to nil.
    func testAPreferenceWithNoStoredNameStillResolves() {
        let store = freshStore()
        store.pair(IBClientHello(name: "Mac A", id: "mac-1"))
        store.setPreferred(id: "mac-1")
        XCTAssertEqual(store.preferred?.name, "Mac A")

        let orphan = freshStore()
        orphan.setPreferred(id: "never-seen", at: Date())
        XCTAssertNil(orphan.preferred, "no name and not paired: nothing to hold the door with")
    }

    // MARK: - What each computer's last attempt did

    func testAnAttemptOutcomeIsRecordedAgainstTheRightComputer() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "Mac A", id: "mac-1", platform: "macos"))
        store.noteSeen(IBClientHello(name: "PC", id: "win-1", platform: "windows"))

        store.noteOutcome(.refusedBusy(owner: "Mac A"), for: "win-1")

        XCTAssertEqual(store.seen.first { $0.id == "win-1" }?.lastOutcome, .refusedBusy(owner: "Mac A"))
        XCTAssertNil(store.seen.first { $0.id == "mac-1" }?.lastOutcome,
                     "one computer's outcome must not land on another")
    }

    func testAnOutcomeForAnUnknownComputerIsIgnored() {
        let store = freshStore()
        XCTAssertNil(store.noteOutcome(.streaming, for: "never-knocked"))
    }

    /// A `seenComputers` blob written before this field existed must still
    /// decode — the loader swallows errors and returns `[]`, so a
    /// non-optional field here would wipe every user's history with no error
    /// anywhere (AGENTS.md rule 2).
    func testSeenComputersWrittenByAnOlderBuildStillDecode() throws {
        let legacy = """
        [{"id":"mac-1","name":"Mac A","platform":"macos","lastSeen":700000000}]
        """
        let decoded = try JSONDecoder().decode([SeenComputer].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "mac-1")
        XCTAssertEqual(decoded[0].name, "Mac A")
        XCTAssertNil(decoded[0].lastOutcome, "absent means unknown, not a crash")
    }

    func testOutcomesRoundTripThroughJSON() throws {
        let all: [AttemptOutcome] = [
            .streaming, .waitingApproval, .refusedBusy(owner: "Mac A"), .denied,
        ]
        for outcome in all {
            var seen = SeenComputer(id: "x", name: "X", platform: "windows")
            seen.lastOutcome = outcome
            let back = try JSONDecoder().decode(
                SeenComputer.self, from: JSONEncoder().encode(seen)
            )
            XCTAssertEqual(back.lastOutcome, outcome)
        }
    }

    func testEveryOutcomeHasUserFacingWording() {
        for outcome in [AttemptOutcome.streaming, .waitingApproval, .denied] {
            XCTAssertFalse(outcome.summary.isEmpty, "\(outcome) has no label")
        }
        XCTAssertFalse(AttemptOutcome.refusedBusy(owner: "Mac A").summary.isEmpty)
    }

    // MARK: - Platform handshake (Windows vs macOS)

    func testClientHelloDecodesWithoutPlatformAsMacOS() throws {
        // An older Mac sends no `platform` key at all.
        let json = """
        {"name":"Old Mac","id":"mac-1","token":null,"appVersion":"0.2"}
        """
        let hello = try JSONDecoder().decode(IBClientHello.self, from: Data(json.utf8))
        XCTAssertNil(hello.platform)
        XCTAssertEqual(hello.resolvedPlatform, "macos")
    }

    func testClientHelloRoundTripsWindowsPlatform() throws {
        let hello = IBClientHello(name: "DESKTOP-7X2K", id: "pc-1",
                                  appVersion: "0.1", platform: "windows")
        let encoded = try IBWire.encode(clientHello: hello)
        let frames = IBWire.Parser().append(encoded)
        let decoded = try IBWire.decodeClientHello(frames[0])
        XCTAssertEqual(decoded.platform, "windows")
        XCTAssertEqual(decoded.resolvedPlatform, "windows")
    }

    // MARK: - Seen computers (the "Choose a computer" list)

    func testNoteSeenRecordsBeforeAnyPairing() {
        let store = freshStore()
        // A brand-new Windows PC that has never been approved.
        store.noteSeen(IBClientHello(name: "Edwin-PC", id: "pc-1", platform: "windows"))

        XCTAssertEqual(store.seen.count, 1)
        XCTAssertEqual(store.seen[0].name, "Edwin-PC")
        XCTAssertTrue(store.seen[0].isWindows)
        XCTAssertEqual(store.platform(for: "pc-1"), "windows")
        // It is NOT paired — that's the point.
        XCTAssertTrue(store.paired.isEmpty)
    }

    func testNoteSeenDeduplicatesAndKeepsNewestFirst() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "Mac A", id: "mac-1"))
        store.noteSeen(IBClientHello(name: "PC B", id: "pc-1", platform: "windows"))
        store.noteSeen(IBClientHello(name: "Mac A Renamed", id: "mac-1"))

        XCTAssertEqual(store.seen.count, 2, "re-seeing an id must not duplicate it")
        XCTAssertEqual(store.seen[0].id, "mac-1", "most recent first")
        XCTAssertEqual(store.seen[0].name, "Mac A Renamed")
        XCTAssertEqual(store.seen[1].platform, "windows")
    }

    func testSeenIsCapped() {
        let store = freshStore()
        for i in 0..<(MacPairingStore.seenLimit + 5) {
            store.noteSeen(IBClientHello(name: "PC \(i)", id: "pc-\(i)", platform: "windows"))
        }
        XCTAssertEqual(store.seen.count, MacPairingStore.seenLimit)
        // The newest survived; the oldest fell off.
        XCTAssertEqual(store.seen.first?.id, "pc-\(MacPairingStore.seenLimit + 4)")
        XCTAssertNil(store.platform(for: "pc-0"))
    }

    func testSeenPersists() {
        let suite = "test.remotecrab.seen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = MacPairingStore(defaults: defaults)
        store.noteSeen(IBClientHello(name: "Edwin-PC", id: "pc-1", platform: "windows"))

        let reloaded = MacPairingStore(defaults: defaults)
        XCTAssertEqual(reloaded.seen.count, 1)
        XCTAssertEqual(reloaded.platform(for: "pc-1"), "windows")
    }

    func testForgetSeenRemovesEntry() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "PC", id: "pc-1", platform: "windows"))
        store.forgetSeen(id: "pc-1")
        XCTAssertTrue(store.seen.isEmpty)
        XCTAssertNil(store.platform(for: "pc-1"))
    }

    // MARK: - Superseded identities and stale rows
    //
    // A receiver used to mint a new `pc_id` on every install, and `seen` is
    // keyed by id alone — so every reinstall added a row that could never be
    // removed by id, and the user's picker filled with identical
    // "Windows PC" entries. Two rules, both self-healing.

    private func seen(_ id: String, _ name: String,
                      platform: String = "windows",
                      daysAgo: Double = 0) -> SeenComputer {
        SeenComputer(id: id, name: name, platform: platform,
                     lastSeen: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    /// The reported bug, as a pure function: two ids, one machine.
    func testASupersededIdentityDoesNotLeaveADuplicateRow() {
        // Newest first, the way `noteSeen` stores it.
        let out = MacPairingStore.pruned([
            seen("new-id", "EDWIN", daysAgo: 0),
            seen("old-id", "EDWIN", daysAgo: 1),
        ])
        XCTAssertEqual(out.map(\.id), ["new-id"])
    }

    /// Case-insensitive, because the same machine names itself differently
    /// across operating systems.
    func testTheSameNameCollapsesRegardlessOfCase() {
        // Newest first, the way `noteSeen` stores it.
        let out = MacPairingStore.pruned([
            seen("c", "Edwin-PC", daysAgo: 0),
            seen("b", "EDWIN", daysAgo: 1),
            seen("a", "edwin", daysAgo: 2),
        ])
        XCTAssertEqual(out.map(\.id), ["c", "b"])
    }

    /// The cost of the rule, stated as a decision: a genuinely different
    /// machine is only collapsed when it shares a hostname.
    func testDifferentNamesAllSurvive() {
        let out = MacPairingStore.pruned([
            seen("mac", "MacBook Pro", platform: "macos", daysAgo: 3),
            seen("pc", "Gaming PC", daysAgo: 2),
            seen("lin", "build-box", platform: "linux", daysAgo: 1),
        ])
        XCTAssertEqual(out.map(\.id), ["lin", "pc", "mac"])
    }

    func testARowExpiresAfterTheTTL() {
        let ttl: TimeInterval = 60
        let now = Date()
        // Explicit timestamps: this rule is about a 60-second window, so a
        // `daysAgo` helper would put every fixture on the wrong side of it.
        func at(_ secondsAgo: TimeInterval) -> SeenComputer {
            SeenComputer(id: "x", name: "PC", platform: "windows",
                         lastSeen: now.addingTimeInterval(-secondsAgo))
        }
        let out = MacPairingStore.pruned([
            SeenComputer(id: "fresh", name: "PC A", platform: "windows", lastSeen: now),
            SeenComputer(id: "edge", name: "PC B", platform: "windows",
                         lastSeen: now.addingTimeInterval(-30)),
            at(3600),
        ], now: now, ttl: ttl)
        XCTAssertEqual(out.map(\.id), ["fresh", "edge"])
    }

    /// Exactly at the TTL is expired, not fresh — a boundary that must not
    /// depend on which side of `<` a refactor lands on.
    func testTheTTLBoundaryIsExclusive() {
        let ttl: TimeInterval = 60
        let now = Date()
        let at = SeenComputer(id: "x", name: "PC", platform: "windows",
                              lastSeen: now.addingTimeInterval(-ttl))
        XCTAssertTrue(MacPairingStore.pruned([at], now: now, ttl: ttl).isEmpty)
    }

    /// Entries written in the same instant really do tie, and the row order
    /// must not then depend on hash order.
    func testEqualTimestampsStillProduceADeterministicOrder() {
        // ONE shared timestamp. `seen(_:_:daysAgo: 0)` calls `Date()` per
        // entry, so the "tied" fixtures were microseconds apart and this
        // was really testing the recency sort again.
        let stamp = Date()
        let entries = ["c", "a", "b"].map {
            SeenComputer(id: $0, name: $0.uppercased(), platform: "windows", lastSeen: stamp)
        }
        XCTAssertEqual(MacPairingStore.pruned(entries).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(MacPairingStore.pruned(entries.reversed()).map(\.id), ["a", "b", "c"])
    }

    func testPruningPreservesNewestFirstOrder() {
        let out = MacPairingStore.pruned([
            seen("a", "A", daysAgo: 0),
            seen("b", "B", daysAgo: 3),
            seen("c", "C", daysAgo: 1),
        ])
        XCTAssertEqual(out.map(\.id), ["a", "c", "b"])
    }

    // MARK: - Store integration

    func testKnockingUnderANewIdCollapsesTheOldRowOnDisk() {
        let suite = "test.remotecrab.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MacPairingStore(defaults: defaults)

        store.noteSeen(IBClientHello(name: "EDWIN", id: "id-1", platform: "windows"))
        store.noteSeen(IBClientHello(name: "EDWIN", id: "id-2", platform: "windows"))
        XCTAssertEqual(store.seen.map(\.id), ["id-2"])
        // Persisted, not just in memory — the picker re-reads from disk.
        XCTAssertEqual(MacPairingStore(defaults: defaults).seen.map(\.id), ["id-2"])
    }

    /// A preference naming a row that pruning removes is cleared. Left
    /// dangling it would keep answering every other computer "in use" for a
    /// machine that can no longer connect.
    func testPruningClearsADanglingPreference() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "EDWIN", id: "old", platform: "windows"))
        store.setPreferred(id: "old", name: "EDWIN")
        store.noteSeen(IBClientHello(name: "EDWIN", id: "new", platform: "windows"))
        XCTAssertNil(store.preferredId, "the armed preference named a computer that no longer exists")
    }

    /// 「Forget」has to make the computer go away.
    ///
    /// The picker lists `seen`, not `paired`, so clearing only the approval
    /// left the machine in "Choose a Computer" as a "not paired" row — and
    /// the row itself is a button that arms a preference, not one that
    /// deletes, so there was no way to remove it short of waiting out the
    /// 30-day expiry.
    func testForgettingAComputerAlsoRemovesItsPickerRow() {
        let suite = "test.remotecrab.pairing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MacPairingStore(defaults: defaults)
        let hello = IBClientHello(name: "EDWIN", id: "pc-1", platform: "windows")
        store.noteSeen(hello)
        store.pair(hello)
        store.setPreferred(id: "pc-1", name: "EDWIN")
        XCTAssertEqual(store.paired.count, 1)
        XCTAssertEqual(store.seen.count, 1)

        store.forget(id: "pc-1")

        XCTAssertTrue(store.paired.isEmpty, "approval survived")
        XCTAssertTrue(store.seen.isEmpty, "still listed in the picker")
        XCTAssertNil(store.preferredId, "preference survived")
        XCTAssertNil(store.platform(for: "pc-1"))
        // Persisted, not just in memory.
        XCTAssertTrue(MacPairingStore(defaults: defaults).seen.isEmpty)
    }

    // MARK: - Which computers the picker lists

    /// The regression: the row filter also compared **names**, so two
    /// computers sharing a hostname meant one of them was not in the list at
    /// all — you could not pick it, which is indistinguishable from "the
    /// switch is broken".
    func testTwoComputersWithTheSameNameAreBothListed() {
        let rows = MacPairingStore.pickerRows(seen: [
            SeenComputer(id: "win-1", name: "EDWIN", platform: "windows"),
            SeenComputer(id: "mac-1", name: "EDWIN", platform: "macos"),
        ], connectedId: nil)
        XCTAssertEqual(Set(rows.map(\.id)), ["win-1", "mac-1"])
    }

    func testTheConnectedComputerIsTheOnlyOneHidden() {
        let rows = MacPairingStore.pickerRows(seen: [
            SeenComputer(id: "a", name: "Mac A", platform: "macos"),
            SeenComputer(id: "b", name: "Mac B", platform: "macos"),
            SeenComputer(id: "c", name: "Mac A", platform: "macos"),
        ], connectedId: "a")
        XCTAssertEqual(Set(rows.map(\.id)), ["b", "c"],
                       "a same-named machine must survive its twin connecting")
    }

    /// A pending computer stays in the list on purpose: re-picking it is how
    /// a stuck switch is recovered.
    func testAPendingComputerIsStillListed() {
        let rows = MacPairingStore.pickerRows(seen: [
            SeenComputer(id: "p", name: "New PC", platform: "windows"),
        ], connectedId: nil)
        XCTAssertEqual(rows.map(\.id), ["p"])
    }

    func testNothingConnectedListsEverything() {
        let rows = MacPairingStore.pickerRows(seen: [
            SeenComputer(id: "a", name: "A", platform: "macos"),
            SeenComputer(id: "b", name: "B", platform: "macos"),
        ], connectedId: nil)
        XCTAssertEqual(rows.count, 2)
    }

    /// `pruneStale` must guarantee no preference names a missing computer —
    /// even when the prune removed nothing. A preference for an id that was
    /// never in `seen` (which `setPreferred` accepts: it takes any string)
    /// would otherwise sit armed and answer every other machine "in use"
    /// until the TTL ran out.
    func testAPreferenceForAComputerThatWasNeverSeenIsCleared() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "Real PC", id: "real", platform: "windows"))
        store.setPreferred(id: "never-seen", name: "Ghost PC")
        XCTAssertEqual(store.seen.count, 1)
        XCTAssertFalse(store.pruneStale(), "nothing was removed")
        XCTAssertNil(store.preferredId, "the ghost preference survived a no-op prune")
    }

    // MARK: - The grace period on a computer switch
    //
    // A user picks a computer to switch to; the phone refuses every OTHER
    // computer so the chosen one can take over. If the chosen one never
    // arrives, that refusal used to last the full 10-minute TTL — so a
    // single failed switch locked the phone out entirely, with the only
    // escape a Cancel button the user has to know exists. Four real Mac
    // states mean the chosen computer is not coming: asleep, on another
    // network, denied (which schedules no retry at all), or auto-reconnect
    // switched off.

    func testTheDoorIsHeldWhileTheGraceIsRunning() {
        let store = freshStore()
        let armed = Date()
        store.noteSeen(IBClientHello(name: "New PC", id: "target", platform: "windows"))
        store.setPreferred(id: "target", name: "New PC", at: armed)
        XCTAssertNotNil(store.effectivePreferred(now: armed.addingTimeInterval(5)),
                        "a computer that might still arrive must be waited for")
    }

    func testTheDoorReopensOnceTheGraceIsSpent() {
        let store = freshStore()
        let armed = Date()
        store.noteSeen(IBClientHello(name: "New PC", id: "target", platform: "windows"))
        store.setPreferred(id: "target", name: "New PC", at: armed)
        let after = armed.addingTimeInterval(MacPairingStore.preferredGrace + 1)
        XCTAssertNil(store.effectivePreferred(now: after),
                     "the door is still held — everyone is locked out for nothing")
    }

    /// Exactly at the boundary is spent, like the expiry TTL: which side of
    /// `<` a refactor lands on must not change the answer.
    func testTheGraceBoundaryIsExclusive() {
        let store = freshStore()
        let armed = Date()
        store.setPreferred(id: "x", name: "X", at: armed)
        XCTAssertNil(store.effectivePreferred(
            now: armed.addingTimeInterval(MacPairingStore.preferredGrace)))
    }

    /// The 10-minute TTL is a different question and still applies: it is how
    /// long the preference is remembered at all. The grace must therefore be
    /// well inside it, or the grace is pointless.
    func testTheGraceIsShorterThanTheTTL() {
        XCTAssertLessThan(MacPairingStore.preferredGrace, MacPairingStore.preferredTTL)
    }

    /// And the grace has to outlast a `busy` Mac's only retry, which is 15 s
    /// (`scheduleSlowRetry`). A shorter grace would abandon exactly the case
    /// that was about to succeed.
    func testTheGraceOutlastsTheMacsSlowRetry() {
        XCTAssertGreaterThan(MacPairingStore.preferredGrace, 15)
    }

    /// No preference armed means nothing holds the door — the unchanged case.
    func testNoPreferenceHoldsNothing() {
        XCTAssertNil(freshStore().effectivePreferred())
    }

    /// The last recorded outcome, which is what lets the waiting banner say
    /// *why*. `denied` is the important one: the Mac schedules no retry at
    /// all, so without this the user waits for something that will never
    /// happen.
    func testTheChosenComputersLastOutcomeIsReadable() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "New PC", id: "target", platform: "windows"))
        XCTAssertNil(store.lastOutcome(for: "target"))
        store.noteOutcome(.denied, for: "target")
        XCTAssertEqual(store.lastOutcome(for: "target"), .denied)
        XCTAssertNil(store.lastOutcome(for: "never-met"))
    }

    /// The one thing pruning must never do: touch the allow-list. An
    /// approval carries a token, and dropping it would force a re-approval
    /// for a machine that is still perfectly well paired.
    func testPruningNeverTouchesTheAllowList() {
        let store = freshStore()
        let hello = IBClientHello(name: "EDWIN", id: "old", platform: "windows")
        store.noteSeen(hello)
        store.pair(hello)
        store.noteSeen(IBClientHello(name: "EDWIN", id: "new", platform: "windows"))
        XCTAssertEqual(store.paired.map(\.id), ["old"], "the token must survive a display prune")
        XCTAssertEqual(store.seen.map(\.id), ["new"])
    }

    /// A brand-new machine must never be pruned for being unseen — it just
    /// knocked, and it is exactly the case the picker exists for.
    func testABrandNewComputerIsNeverPruned() {
        let store = freshStore()
        store.noteSeen(IBClientHello(name: "New PC", id: "brand-new", platform: "windows"))
        XCTAssertEqual(store.seen.map(\.id), ["brand-new"])
    }
}
