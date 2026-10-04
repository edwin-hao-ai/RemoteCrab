import XCTest
@testable import RemoteCrabCore

final class VideoEncodingPolicyTests: XCTestCase {

    // MARK: - Sharpness, which is decided by Quality and not by the bitrate

    /// `kVTCompressionPropertyKey_Quality` overrides
    /// `kVTCompressionPropertyKey_AverageBitRate` on iOS. Measured with
    /// `scripts/vt-bitrate-probe.swift` (1920x1080 @ 30fps, `AverageBitRate`
    /// held at 9,331,200, bytes over 90 frames):
    ///
    /// | Quality | achieved |
    /// |--------|----------|
    /// | 0.50   | 4,989 kbps |
    /// | 0.70   | 9,179 kbps |
    /// | 0.75   | 10,886 kbps |
    /// | 0.80   | 13,552 kbps |
    /// | 0.90   | 22,404 kbps |
    ///
    /// 0.70 was what shipped, and a peer reporting "6220 kbps" — the phone's
    /// own request — was read as the cause of a soft picture. It was not: the
    /// request had no effect at all. This pins the value that does.
    func testQualityIsTheSharpnessDialAndItWentUp() {
        XCTAssertEqual(VideoEncodingPolicy.quality, 0.75, accuracy: 0.0001,
                       "0.70 shipped and measured 9,179 kbps; see the probe table")
    }

    /// The knob must stay inside the range where the encoder actually
    /// responds. At 0.0 VideoToolbox treats quality as "lossless", which on a
    /// live camera would be an unusable bitrate; above 1.0 it is undefined.
    func testQualityStaysInTheRangeTheEncoderHonours() {
        XCTAssertGreaterThan(VideoEncodingPolicy.quality, 0)
        XCTAssertLessThanOrEqual(VideoEncodingPolicy.quality, 1.0)
    }

    // MARK: - The number the Windows receiver read back

    /// What the phone *asks for*, and what it reports in `IBStreamMetadata`.
    /// A Windows machine measured `6220 kbps` for 1080x1920@30, which was
    /// exactly `1920 × 1080 × 30 × 0.1` — the coefficient echoed back, not a
    /// measurement. Pinned so nobody reads this figure as a quality signal.
    func test1080p30AsksForNinePointThreeMbps() {
        XCTAssertEqual(
            VideoEncodingPolicy.bitrate(width: 1920, height: 1080, fps: 30),
            9_331_200)
    }

    /// The phone reports the rate it *asked for* in `IBStreamMetadata`, so a
    /// higher figure there is not evidence of a sharper picture. Only the
    /// achieved rate is. This test exists so that distinction has a name in
    /// the suite rather than living in a comment.
    func testAchievedRateIsMeasuredInBitsNotBytes() {
        // 1 MiB over one second is 8,388,608 bits — not 1,048,576.
        XCTAssertEqual(
            VideoEncodingPolicy.achievedBitsPerSecond(bytes: 1_048_576, seconds: 1),
            8_388_608)
    }

    func testAchievedRateIsZeroForAnEmptyOrZeroLengthWindow() {
        // A divide-by-zero here would print "inf kbps" and be read as a
        // passing measurement.
        XCTAssertEqual(VideoEncodingPolicy.achievedBitsPerSecond(bytes: 0, seconds: 2), 0)
        XCTAssertEqual(VideoEncodingPolicy.achievedBitsPerSecond(bytes: 999, seconds: 0), 0)
    }

    // MARK: - Shape of the curve

    /// A user reporting "it looks soft" at one resolution and "it looks fine"
    /// at another is the signature of a curve that is not monotonic — and a
    /// non-monotonic bitrate curve is invisible in a screenshot. Adding
    /// pixels may never buy *fewer* bits; the ceiling is allowed to make it
    /// flat, never to make it fall.
    func testAddingPixelsNeverReducesTheRequestedBitrate() {
        let formats = [(320, 240), (640, 480), (1280, 720), (1920, 1080),
                       (2560, 1440), (3840, 2160)]
        var previous = 0
        for (width, height) in formats {
            let bps = VideoEncodingPolicy.bitrate(width: width, height: height, fps: 30)
            XCTAssertGreaterThanOrEqual(bps, previous,
                                       "\(width)x\(height) got fewer bits than a smaller format")
            previous = bps
        }
    }

    func testFrameRateIsPartOfTheBudget() {
        // 30 fps must not cost the same as 60 fps at the same resolution, or
        // a resolution switch silently halves the rate per frame.
        // 720p is used because it is the largest size where the ceiling does
        // not bind, so this measures the coefficient rather than the clamp.
        let at30 = VideoEncodingPolicy.bitrate(width: 1280, height: 720, fps: 30)
        let at60 = VideoEncodingPolicy.bitrate(width: 1280, height: 720, fps: 60)
        XCTAssertEqual(at60, at30 * 2)
    }

    /// 60 fps is a user-selectable frame rate, and at 1080p it wants
    /// 18.66 Mbps — over the ceiling. So the coefficient is *not* fully
    /// honoured there and the effective rate per pixel drops to ~0.129.
    /// That is still better than the 0.1 that shipped, but it is a clamp
    /// doing the limiting, so it is pinned here rather than left for the
    /// next person to discover from a soft picture at 60 fps.
    func testTheCeilingBindsAt1080p60() {
        XCTAssertEqual(VideoEncodingPolicy.bitrate(width: 1920, height: 1080, fps: 30), 9_331_200)
        XCTAssertEqual(VideoEncodingPolicy.bitrate(width: 1920, height: 1080, fps: 60),
                       VideoEncodingPolicy.ceilingBps)
    }

    func testFloorProtectsTinyFormatsAndCeilingCapsEnormousOnes() {
        XCTAssertEqual(VideoEncodingPolicy.bitrate(width: 64, height: 64, fps: 5),
                       VideoEncodingPolicy.floorBps)
        XCTAssertEqual(VideoEncodingPolicy.bitrate(width: 7680, height: 4320, fps: 60),
                       VideoEncodingPolicy.ceilingBps)
    }

    /// The ceiling exists so the coefficient is not silently truncated at high
    /// resolutions. If it were not load-bearing, the coefficient would be
    /// decorative above 1080p and nobody would notice.
    func testTheCeilingIsReachableButOnlyByGenuinelyLargeFormats() {
        let at1080p = VideoEncodingPolicy.bitrate(width: 1920, height: 1080, fps: 30)
        XCTAssertLessThan(at1080p, VideoEncodingPolicy.ceilingBps,
                          "1080p30 must not be pinned to the ceiling")
        XCTAssertEqual(VideoEncodingPolicy.bitrate(width: 3840, height: 2160, fps: 30),
                       VideoEncodingPolicy.ceilingBps)
    }

    // MARK: - Keyframes

    /// The reason the interval was doubled: with one I-frame per second, the
    /// other 29 P-frames had almost nothing to spend, which is what produced
    /// periodic horizontal banding. An interval that leaves no P-frames at all
    /// would reintroduce it in a different form.
    func testTheKeyframeIntervalLeavesPFramesToBudgetBits() {
        let interval = VideoEncodingPolicy.maxKeyFrameInterval(fps: 30)
        XCTAssertGreaterThan(interval, 30, "every frame a keyframe spends the whole budget on I-frames")
    }

    /// The cost of a longer GOP is a decoder joining a *running* stream
    /// waiting for a keyframe, so the interval is a promise about recovery
    /// time and belongs in seconds, bounded.
    func testTheKeyframeIntervalBoundsWorstCaseRecovery() {
        for fps in [15, 24, 30, 60] {
            let seconds = Double(VideoEncodingPolicy.maxKeyFrameInterval(fps: fps)) / Double(fps)
            XCTAssertLessThanOrEqual(seconds, 2.0, "\(fps) fps: recovery would exceed 2 s")
        }
    }

    func testAZeroFrameRateCannotProduceAZeroInterval() {
        // VideoToolbox treats an interval of 0 as "every frame", which is the
        // degenerate case the previous assertion forbids.
        XCTAssertGreaterThanOrEqual(VideoEncodingPolicy.maxKeyFrameInterval(fps: 0), 1)
    }
}