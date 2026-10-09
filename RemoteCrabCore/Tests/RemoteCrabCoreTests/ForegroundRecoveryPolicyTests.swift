import XCTest
@testable import RemoteCrabCore

final class ForegroundRecoveryPolicyTests: XCTestCase {

    private let allLiveness: [ForegroundRecoveryPolicy.ListenerLiveness] =
        [.absent, .ready, .failed, .cancelled, .other]

    /// A live session must never be torn down to rebuild the listener:
    /// `stopStreaming()/startStreaming()` cancels the connection (lesson 156).
    func testALiveLinkIsNeverRebuilt() {
        for liveness in allLiveness {
            XCTAssertFalse(
                ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: true, listener: liveness),
                "link alive + \(liveness) must not rebuild the listener")
        }
    }

    /// The incident of 2026-10-09: the listener answered `failed`
    /// (`DefunctConnection`) on foreground return, so the phone was
    /// unreachable even though the app kept streaming video. It must rebuild.
    func testAFailedListenerIsRebuilt() {
        XCTAssertTrue(ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: false, listener: .failed))
    }

    /// `stopStreaming()` clears the listener; a rebuild is the only way back.
    func testAnAbsentListenerIsRebuilt() {
        XCTAssertTrue(ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: false, listener: .absent))
    }

    func testACancelledListenerIsRebuilt() {
        XCTAssertTrue(ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: false, listener: .cancelled))
    }

    /// A healthy listener is exactly what lesson 156 was about — leave it.
    func testAReadyListenerIsLeftAlone() {
        XCTAssertFalse(ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: false, listener: .ready))
    }

    /// `.setup` / `.waiting` are not clearly dead; rebuilding could tear down a
    /// listener that is about to become ready.
    func testAnIndeterminateListenerIsLeftAlone() {
        XCTAssertFalse(ForegroundRecoveryPolicy.shouldRebuildListener(linkAlive: false, listener: .other))
    }
}
