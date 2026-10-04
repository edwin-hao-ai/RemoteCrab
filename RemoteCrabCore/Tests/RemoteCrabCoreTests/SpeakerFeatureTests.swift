import XCTest
@testable import RemoteCrabCore

/// `.speaker` in the feature store, plus the format-compatibility guard
/// that AGENTS.md rule 2 demands for every new persisted field.
@MainActor
final class SpeakerFeatureTests: XCTestCase {

    func testDefaultsToOff() {
        let store = FeatureStore()
        XCTAssertFalse(store.speakerOn, "turning this on starts the receiver capturing audio")
    }

    func testSetTogglesAndNotifiesOnce() {
        let store = FeatureStore()
        var notifications = 0
        store.onChange = { _ in notifications += 1 }

        store.set(feature: .speaker, enabled: true)
        XCTAssertTrue(store.speakerOn)
        XCTAssertEqual(notifications, 1)

        // A redundant set is a genuine no-op with no broadcast, so a state
        // echo cannot start the receiver's capture twice.
        store.set(feature: .speaker, enabled: true)
        XCTAssertEqual(notifications, 1)
    }

    func testSnapshotCarriesSpeakerState() {
        let store = FeatureStore()
        store.set(feature: .speaker, enabled: true)
        XCTAssertTrue(store.snapshot().speakerOn)
    }

    func testRemoteControlIsIdenticalToALocalToggle() {
        let store = FeatureStore()
        store.apply(FeatureControl(feature: .speaker, enabled: true))
        XCTAssertTrue(store.speakerOn)
        store.apply(FeatureControl(feature: .speaker, enabled: false))
        XCTAssertFalse(store.speakerOn)
    }

    func testEveryFeatureIsReachableAndRoundTrips() {
        // FeatureStore.set has a hand-written, non-exhaustive switch: adding
        // an enum case without an arm is a COMPILE error, but forgetting to
        // carry it into the snapshot is silent — the state would never reach
        // the peer. This walks the whole enum instead of trusting the switch.
        let store = FeatureStore()
        for feature in IBFeature.allCases {
            store.set(feature: feature, enabled: true)
            switch feature {
            case .camera: XCTAssertTrue(store.cameraOn)
            case .microphone: XCTAssertTrue(store.micOn)
            case .voice: XCTAssertTrue(store.voiceOn)
            case .trackpad: XCTAssertTrue(store.trackpadOn)
            case .keyboard: XCTAssertTrue(store.keyboardOn)
            case .screen: XCTAssertTrue(store.screenOn)
            case .speaker: XCTAssertTrue(store.speakerOn)
            }
            store.set(feature: feature, enabled: false)
        }
    }

    // MARK: - Rule 2: the previous on-disk / on-wire format must still load

    /// A snapshot produced BEFORE the speaker feature existed has no
    /// `speakerOn` key. Both ends swallow decode errors, so if `init(from:)`
    /// required this field the payload would throw and the peer would
    /// silently lose its entire feature state — not just the new field.
    func testLegacySnapshotWithoutSpeakerKeyStillDecodes() throws {
        let legacy = """
        {
          "cameraOn": true,
          "micOn": true,
          "voiceOn": false,
          "trackpadOn": true,
          "keyboardOn": true,
          "activeSurface": "trackpad",
          "timestampMicros": 1700000000000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(FeatureStateSnapshot.self, from: legacy)
        XCTAssertFalse(decoded.speakerOn, "an absent key must default to off")
        // And nothing else may be lost.
        XCTAssertTrue(decoded.cameraOn)
        XCTAssertTrue(decoded.micOn)
        XCTAssertFalse(decoded.voiceOn)
        XCTAssertTrue(decoded.trackpadOn)
        XCTAssertTrue(decoded.keyboardOn)
        XCTAssertEqual(decoded.activeSurface, .trackpad)
        XCTAssertEqual(decoded.timestampMicros, 1_700_000_000_000_000)
        XCTAssertFalse(decoded.screenOn)
        XCTAssertEqual(decoded.cameraPosition, .back)
    }

    /// The feature's raw value is on the wire inside `featureControl`, and
    /// there is no unknown-case fallback anywhere in that path: an older
    /// receiver throws, the caller `try?`-swallows it, and the tap does
    /// nothing with no error anywhere. So the string is frozen.
    func testFeatureRawValuesAreFrozen() {
        XCTAssertEqual(IBFeature.speaker.rawValue, "speaker")
        XCTAssertEqual(IBFeature.allCases.count, 7)
        // Raw values must stay unique or one feature shadows another.
        XCTAssertEqual(Set(IBFeature.allCases.map(\.rawValue)).count, IBFeature.allCases.count)
    }
}
