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

    // MARK: - Fit vs fill

    func testFillModeCoversTheViewAndAllowsPanAtZoom1() {
        let s = ScreenZoomState(windowWidth: 1600, windowHeight: 900,
                                viewSize: CGSize(width: 400, height: 800),
                                fillsView: true)
        XCTAssertEqual(s.fitSize.width, 1600.0 * 800.0 / 900.0, accuracy: 0.5)
        XCTAssertEqual(s.fitSize.height, 800, accuracy: 0.01)
        XCTAssertEqual(s.maxPan.width, (1422.22 - 400) / 2, accuracy: 1.0)
        XCTAssertEqual(s.maxPan.height, 0, accuracy: 0.01)
        XCTAssertTrue(s.canPan)
    }

    func testSetFillsViewPreservesAnchoredContentPoint() throws {
        var s = makeState()   // fit
        let anchor = CGPoint(x: 100, y: 400)
        let before = try XCTUnwrap(s.contentUV(forViewPoint: anchor))
        s.setFillsView(true, anchor: anchor)
        XCTAssertTrue(s.fillsView)
        let after = try XCTUnwrap(s.contentUV(forViewPoint: anchor))
        XCTAssertEqual(after.u, before.u, accuracy: 0.02)
        XCTAssertEqual(after.v, before.v, accuracy: 0.02)
    }

    // MARK: - Anchored zoom

    func testAnchoredZoomKeepsTheTouchedPointFixed() throws {
        var s = makeState()   // 16:9 fit, content rect (0, 287.5, 400, 225)
        let anchor = CGPoint(x: 300, y: 400)
        let before = try XCTUnwrap(s.contentUV(forViewPoint: anchor))
        s.setZoom(2, anchor: anchor)
        XCTAssertEqual(s.zoom, 2, accuracy: 0.001)
        let after = try XCTUnwrap(s.contentUV(forViewPoint: anchor))
        XCTAssertEqual(after.u, before.u, accuracy: 0.001)
        XCTAssertEqual(after.v, before.v, accuracy: 0.001)
    }

    func testToggleZoomGoesToTwoThenBackToOne() {
        var s = makeState()
        s.toggleZoom(at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(s.zoom, 2, accuracy: 0.001)
        s.toggleZoom(at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(s.zoom, 1, accuracy: 0.001)
    }
}
