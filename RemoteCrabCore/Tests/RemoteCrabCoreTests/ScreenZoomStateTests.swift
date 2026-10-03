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

    func testFitModeHasNothingToPanSoBothAxesScroll() {
        let s = makeState()   // zoom 1 → nothing to pan
        let r = s.twoFinger(axis: .horizontal, translation: CGSize(width: 30, height: 0))
        XCTAssertEqual(r.pan.width, 0, accuracy: 0.001)
        XCTAssertEqual(r.pan.height, 0, accuracy: 0.001)
        XCTAssertEqual(r.scrollDX, 30.0 / 400.0, accuracy: 0.001)
        XCTAssertTrue(r.isScroll)
        let v = s.twoFinger(axis: .vertical, translation: CGSize(width: 0, height: 40))
        XCTAssertEqual(v.scrollDY, 40.0 / 800.0, accuracy: 0.001)
    }

    /// The two-finger gesture is axis-locked now, so "pans while zoomed"
    /// is a THREE-finger statement. Two fingers mean scroll on the locked
    /// axis and pan on the other (see `testTwoFingerAxis*`).
    func testThreeFingerWhileZoomedPansWithoutScrolling() {
        let s = makeState(zoom: 2)
        let r = s.panGesture(translation: CGSize(width: 50, height: 0))
        XCTAssertEqual(r.pan.width, 50, accuracy: 0.01)
        XCTAssertFalse(r.isScroll)
    }

    func testPanGestureAtEdgePansThenScrollsTheResidual() {
        let s = makeState(zoom: 2, pan: CGSize(width: 180, height: 0))
        let r = s.panGesture(translation: CGSize(width: 50, height: 0))
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

    // MARK: - Chrome insets (landscape "pan hides under the top bar")

    /// 16:9 window in a landscape view with a 60pt top bar and 132pt bottom
    /// chrome: the content must sit entirely between them.
    private func makeInsetState() -> ScreenZoomState {
        ScreenZoomState(windowWidth: 1600, windowHeight: 900,
                        viewSize: CGSize(width: 844, height: 390),
                        topInset: 60, bottomInset: 132)
    }

    func testContentIsLaidOutInsideTheChromeInsets() {
        let s = makeInsetState()
        let r = s.fittedContentRect
        XCTAssertGreaterThanOrEqual(r.minY, 60 - 0.001, "content starts below the top bar")
        XCTAssertLessThanOrEqual(r.maxY, 390 - 132 + 0.001, "content ends above the bottom chrome")
    }

    func testPanCanPullTheContentFullyBelowTheTopBar() {
        var s = makeInsetState()
        s.setZoom(2)
        // Drag down as far as the model allows.
        s.commitPan(CGSize(width: 0, height: 10_000))
        XCTAssertEqual(s.displayedContentRect.minY, 60, accuracy: 0.01,
                       "full downward pan parks the top edge at the inset, not off-screen")
        // And up.
        s.commitPan(CGSize(width: 0, height: -10_000))
        XCTAssertEqual(s.displayedContentRect.maxY, 390 - 132, accuracy: 0.01)
    }

    func testTouchesOutsideTheContentAreIgnoredEvenWithInsets() {
        let s = makeInsetState()
        // Just below the top bar but above the window (letterbox): the
        // window fits by width, so it is 844*900/1600 = 474 tall — taller
        // than the band, so use a narrow window instead.
        let tall = ScreenZoomState(windowWidth: 900, windowHeight: 1600,
                                   viewSize: CGSize(width: 844, height: 390),
                                   topInset: 60, bottomInset: 132)
        // The 9:16 content fits by height in the band: 198 tall, centred.
        XCTAssertNil(tall.contentUV(forViewPoint: CGPoint(x: 422, y: 30)),
                     "a touch in the top chrome area is not on the window")
    }

    func testPanGestureScrollsWhenFittedEvenWithInsets() {
        // Regression: with chrome insets the fitted content is taller than
        // the usable band, which used to make a drag PAN instead of scroll.
        // At zoom 1 / fit the pan gesture must scroll.
        var s = makeInsetState()
        let r = s.panGesture(translation: CGSize(width: 0, height: 40))
        XCTAssertTrue(r.isScroll, "a pan-gesture drag at fit zoom is a content scroll")
        XCTAssertEqual(r.pan.height, s.pan.height, accuracy: 0.001, "no pan at fit zoom")
        XCTAssertEqual(r.scrollDY, 40.0 / 390.0, accuracy: 0.001)
    }

    func testPanGesturePansOnceZoomedIn() {
        var s = makeInsetState()
        s.setZoom(2)
        let r = s.panGesture(translation: CGSize(width: 0, height: 10))
        XCTAssertGreaterThan(r.pan.height, s.pan.height, "zoomed-in pan gesture pans the content")
    }

    // MARK: - Two-finger axis lock

    func testAxisIsUndecidedBelowTheThreshold() {
        // A finger resting on the glass must not pick an axis — that is
        // what made a stationary two-finger touch jitter the remote app.
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 4, height: -6)), .undecided)
        XCTAssertEqual(ScreenDragAxis.decide(.zero), .undecided)
    }

    func testAxisPrefersVerticalOnADiagonal() {
        // Fingers almost always drift sideways while scrolling up/down, so
        // a near-diagonal must resolve to VERTICAL (libinput's rule).
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 10, height: -14)), .vertical)
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 11, height: -12)), .vertical)
    }

    func testAxisNeedsAClearHorizontalWin() {
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 40, height: -6)), .horizontal)
        // 26 vs 20 is diagonal, not a deliberate sideways swipe.
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 26, height: -20)), .vertical)
    }

    func testAxisDecidesFromTheAccumulatedTravelNotOneDelta() {
        // The gesture accumulates: many small vertical deltas must still
        // decide vertical even when no single delta crosses the threshold.
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 2, height: -5)), .undecided)
        XCTAssertEqual(ScreenDragAxis.decide(CGSize(width: 6, height: -20)), .vertical)
    }

    /// THE regression this whole change exists for: a two-finger swipe up
    /// or down must scroll the remote app even when zoomed in. It used to
    /// be latched into `.pan` for the gesture's whole lifetime, which is
    /// exactly "双指上下滚动失灵，被感应成拖动镜像".
    func testTwoFingerVerticalSwipeScrollsEvenWhenZoomedIn() {
        var s = makeState(zoom: 3)
        let axis = ScreenDragAxis.decide(CGSize(width: 4, height: -40))
        XCTAssertEqual(axis, .vertical)
        let r = s.twoFinger(axis: axis, translation: CGSize(width: 4, height: -40))
        XCTAssertEqual(r.pan, .zero, "a vertical two-finger swipe must not pan")
        XCTAssertEqual(r.scrollDY, -40.0 / 800.0, accuracy: 0.0001)
        XCTAssertEqual(r.scrollDX, 0, accuracy: 0.0001, "the cross axis is dropped")
    }

    func testTwoFingerHorizontalSwipePansWhenZoomedIn() {
        var s = makeState(zoom: 3)
        let r = s.twoFinger(axis: .horizontal, translation: CGSize(width: 40, height: -4))
        XCTAssertGreaterThan(r.pan.width, 0, "horizontal two-finger pans the mirror")
        XCTAssertEqual(r.pan.height, 0, accuracy: 0.0001)
        XCTAssertFalse(r.isScroll)
    }

    func testTwoFingerHorizontalSwipeScrollsWhenThereIsNothingToPan() {
        // Fit zoom: the content cannot pan, so the locked axis scrolls the
        // remote app instead of doing nothing at all.
        let s = makeState(zoom: 1)
        let r = s.twoFinger(axis: .horizontal, translation: CGSize(width: 40, height: -4))
        XCTAssertEqual(r.pan, .zero)
        XCTAssertEqual(r.scrollDX, 40.0 / 400.0, accuracy: 0.0001)
        XCTAssertEqual(r.scrollDY, 0, accuracy: 0.0001)
    }

    func testTwoFingerUndecidedAxisDoesNothing() {
        let s = makeState(zoom: 3)
        let r = s.twoFinger(axis: .undecided, translation: CGSize(width: 2, height: -3))
        XCTAssertEqual(r.pan, .zero)
        XCTAssertFalse(r.isScroll, "nothing is sent until an axis is chosen")
    }

    // MARK: - Tap vs drag slop

    func testDragSlopGrowsWithZoom() {
        // A tap near a button must not become a Mac drag just because the
        // view is magnified: the slop is a CONTENT distance, so it has to
        // be divided by the zoom to stay 10 content points of travel.
        var s = makeState()
        XCTAssertEqual(s.dragSlop, 10, accuracy: 0.001)          // unchanged at 1x
        s.setZoom(2); XCTAssertEqual(s.dragSlop, 10, accuracy: 0.001)
        s.setZoom(4); XCTAssertEqual(s.dragSlop, 16, accuracy: 0.001)
        // Capped so a future maxZoom bump cannot make a tap unrecognisable.
        XCTAssertLessThanOrEqual(s.dragSlop, 28)
    }
}
