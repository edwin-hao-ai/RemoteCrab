import XCTest
@testable import iBridgeCore

@MainActor
final class FeatureStoreTests: XCTestCase {

    func testDefaultsMatchV02Behavior() {
        let store = FeatureStore()
        XCTAssertTrue(store.cameraOn)
        XCTAssertFalse(store.micOn)
        XCTAssertFalse(store.voiceOn)
        XCTAssertTrue(store.trackpadOn)
        XCTAssertTrue(store.keyboardOn)
        XCTAssertEqual(store.activeSurface, .cameraPreview)
    }

    func testSetFeatureFlipsAndNotifies() {
        let store = FeatureStore()
        var snapshots: [FeatureStateSnapshot] = []
        store.onChange = { snapshots.append($0) }
        store.set(feature: .microphone, enabled: true)
        XCTAssertTrue(store.micOn)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots[0].micOn)
        // Setting to the same value is a no-op (no redundant broadcast).
        store.set(feature: .microphone, enabled: true)
        XCTAssertEqual(snapshots.count, 1)
    }

    func testApplyFeatureControl() {
        let store = FeatureStore()
        store.apply(FeatureControl(feature: .camera, enabled: false))
        XCTAssertFalse(store.cameraOn)
    }

    func testSnapshotCarriesAllFields() {
        let store = FeatureStore()
        store.set(feature: .voice, enabled: true)
        store.activeSurface = .keyboard
        let snap = store.snapshot()
        XCTAssertTrue(snap.voiceOn)
        XCTAssertEqual(snap.activeSurface, .keyboard)
        XCTAssertGreaterThan(snap.timestampMicros, 0)
    }
}
