import XCTest
@testable import RemoteCrabCore

final class UpdateInstallGateTests: XCTestCase {
    private let gate = UpdateInstallGate(dwell: 30)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoPendingUpdateNeverInstalls() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: false, sessionActive: false,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testActiveSessionBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: true,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testRecordingBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: true, idleSince: t0, now: t0.addingTimeInterval(60)))
    }

    func testIdleSinceNilBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: false, idleSince: nil, now: t0))
    }

    func testBeforeDwellBlocks() {
        XCTAssertFalse(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                          isRecording: false, idleSince: t0, now: t0.addingTimeInterval(29)))
    }

    func testExactlyAtDwellInstalls() {
        XCTAssertTrue(gate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                         isRecording: false, idleSince: t0, now: t0.addingTimeInterval(30)))
    }

    func testZeroDwellInstallsImmediately() {
        let zeroGate = UpdateInstallGate(dwell: 0)
        XCTAssertTrue(zeroGate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                             isRecording: false, idleSince: t0, now: t0))
    }

    func testNegativeDwellInstalls() {
        let negativeGate = UpdateInstallGate(dwell: -5)
        XCTAssertTrue(negativeGate.shouldInstall(pendingUpdate: true, sessionActive: false,
                                                 isRecording: false, idleSince: t0, now: t0))
    }
}
