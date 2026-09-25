import XCTest
@testable import RemoteCrabCore

final class H264FrameGateTests: XCTestCase {

    func testAcceptsKeyframeAndFollowingSlices() {
        var gate = H264FrameGate()
        XCTAssertEqual(gate.classify(nalHeader: 0x65), .decode) // IDR (type 5)
        XCTAssertTrue(gate.sawKeyframe)
        XCTAssertEqual(gate.classify(nalHeader: 0x41), .decode) // P-slice (type 1)
    }

    func testDropsPSliceBeforeKeyframe() {
        // Regression: the iPhone stream's first wire frame is a P-slice;
        // feeding it made VideoToolbox report -12909 and the decode session
        // was never rebuilt (recording then had no frames to write).
        var gate = H264FrameGate()
        XCTAssertEqual(gate.classify(nalHeader: 0x41), .dropBeforeKeyframe)
        XCTAssertFalse(gate.sawKeyframe)
        XCTAssertEqual(gate.classify(nalHeader: 0x65), .decode)
        XCTAssertEqual(gate.classify(nalHeader: 0x41), .decode)
    }

    func testDropsNonVCLNALs() {
        // SPS(7), PPS(8), SEI(6), AUD(9) are not standalone samples.
        var gate = H264FrameGate()
        XCTAssertEqual(gate.classify(nalHeader: 0x67), .dropNonVCL)
        XCTAssertEqual(gate.classify(nalHeader: 0x68), .dropNonVCL)
        XCTAssertEqual(gate.classify(nalHeader: 0x06), .dropNonVCL)
        XCTAssertEqual(gate.classify(nalHeader: 0x09), .dropNonVCL)
        XCTAssertFalse(gate.sawKeyframe)
    }

    func testResetRequiresFreshKeyframe() {
        var gate = H264FrameGate()
        _ = gate.classify(nalHeader: 0x65)
        gate.reset()
        XCTAssertFalse(gate.sawKeyframe)
        XCTAssertEqual(gate.classify(nalHeader: 0x41), .dropBeforeKeyframe)
    }
}
