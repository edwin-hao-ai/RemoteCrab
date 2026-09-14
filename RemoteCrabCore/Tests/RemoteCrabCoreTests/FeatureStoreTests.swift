import XCTest
@testable import RemoteCrabCore

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

    func testCameraPositionDefaultsUpdatesAndNotifies() {
        let store = FeatureStore()
        XCTAssertEqual(store.cameraPosition, .back)
        XCTAssertEqual(store.cameraPosition.toggled, .front)

        var snapshots: [FeatureStateSnapshot] = []
        store.onChange = { snapshots.append($0) }
        store.setCameraPosition(.front)
        XCTAssertEqual(store.cameraPosition, .front)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].cameraPosition, .front)

        // Same position is a no-op (no redundant broadcast).
        store.setCameraPosition(.front)
        XCTAssertEqual(snapshots.count, 1)
    }

    func testSnapshotDecodesLegacyPayloadWithoutCameraPosition() throws {
        // Snapshots from builds before front/back switching must still
        // decode, defaulting to the back camera.
        let legacy = """
        {"cameraOn":true,"micOn":false,"voiceOn":false,"trackpadOn":true,\
        "keyboardOn":true,"activeSurface":"cameraPreview","timestampMicros":42}
        """
        let snap = try JSONDecoder().decode(FeatureStateSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snap.cameraPosition, .back)
        XCTAssertTrue(snap.cameraOn)
    }
}
