import XCTest
@testable import RemoteCrabCore

final class ScreenZoomStateTests: XCTestCase {

    /// 400x800 view, 16:9 window → fit is width-limited: 400x225 centered.
    private func makeState(zoom: Double = 1, pan: CGSize = .zero) -> ScreenZoomState {
        ScreenZoomState(windowWidth: 1600, windowHeight: 900,
                        viewSize: CGSize(width: 400, height: 800),
                        zoom: zoom, pan: pan)
    }

    func testFitIsLetterboxedAndCentered() {
        let s = makeState()
        XCTAssertEqual(s.fitSize.width, 400, accuracy: 0.01)
        XCTAssertEqual(s.fitSize.height, 225, accuracy: 0.01)
        XCTAssertEqual(s.fittedContentRect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(s.fittedContentRect.minY, 287.5, accuracy: 0.01)
    }

    func testCenterMapsToHalfHalf() throws {
        let s = makeState()
        let uv = try XCTUnwrap(s.contentUV(forViewPoint: CGPoint(x: 200, y: 400)))
        XCTAssertEqual(uv.u, 0.5, accuracy: 0.001)
        XCTAssertEqual(uv.v, 0.5, accuracy: 0.001)
    }

    func testLetterboxTouchesAreIgnored() {
        let s = makeState()
        XCTAssertNil(s.contentUV(forViewPoint: CGPoint(x: 200, y: 100)))   // top bar
        XCTAssertNil(s.contentUV(forViewPoint: CGPoint(x: 200, y: 700)))   // bottom bar
    }

    func testZoomClampsAndResetsAtMin() {
        var s = makeState()
        s.setZoom(99)
        XCTAssertEqual(s.zoom, ScreenZoomState.maxZoom, accuracy: 0.001)
        s.setZoom(0.1)
        XCTAssertEqual(s.zoom, ScreenZoomState.minZoom, accuracy: 0.001)
    }

    func testPanClampsToContentEdges() {
        let s = makeState(zoom: 2)
        // At 2x: content 800x450 in a 400x800 view → only x overflows.
        XCTAssertEqual(s.maxPan.width, 200, accuracy: 0.01)
        XCTAssertEqual(s.maxPan.height, 0, accuracy: 0.01)
        var m = s
        m.commitPan(CGSize(width: 9999, height: 9999))
        XCTAssertEqual(m.pan.width, 200, accuracy: 0.01)
        XCTAssertEqual(m.pan.height, 0, accuracy: 0.01)
    }

    func testTwoFingerAtFitScrollsTheMacInsteadOfPanning() {
        let s = makeState()   // zoom 1 → nothing to pan
        let r = s.twoFinger(translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(r.pan.width, 0, accuracy: 0.001)
        XCTAssertEqual(r.pan.height, 0, accuracy: 0.001)
        XCTAssertEqual(r.scrollDX, 30.0 / 400.0, accuracy: 0.001)
        XCTAssertEqual(r.scrollDY, 40.0 / 800.0, accuracy: 0.001)
        XCTAssertTrue(r.isScroll)
    }

    func testTwoFingerWhileZoomedPansWithoutScrolling() {
        let s = makeState(zoom: 2)
        let r = s.twoFinger(translation: CGSize(width: 50, height: 0))
        XCTAssertEqual(r.pan.width, 50, accuracy: 0.01)
        XCTAssertFalse(r.isScroll)
    }

    func testTwoFingerAtEdgePansThenScrollsTheResidual() {
        let s = makeState(zoom: 2, pan: CGSize(width: 180, height: 0))
        let r = s.twoFinger(translation: CGSize(width: 50, height: 0))
        XCTAssertEqual(r.pan.width, 200, accuracy: 0.01)          // clamped at edge
        XCTAssertEqual(r.scrollDX, 30.0 / 400.0, accuracy: 0.001) // 50 - 20 residual
    }
}
