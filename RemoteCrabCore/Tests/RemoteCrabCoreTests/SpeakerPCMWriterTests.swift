import AVFoundation
import XCTest
@testable import RemoteCrabCore

final class SpeakerPCMWriterTests: XCTestCase {

    private let frames = 4
    private var left: [Int16] = [100, 200, 300, 400]
    private var right: [Int16] = [900, 800, 700, 600]

    private func makeBuffer(interleaved: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 48_000,
                                   channels: 2,
                                   interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Read a buffer back in the order the wire lays it out, so the assertion
    /// does not itself depend on the layout it is checking.
    private struct Pair: Equatable {
        var l: Int16
        var r: Int16
    }

    private func pairs(_ buffer: AVAudioPCMBuffer) -> [Pair] {
        let planes = buffer.int16ChannelData!
        var out: [Pair] = []
        for frame in 0..<Int(buffer.frameLength) {
            if buffer.format.isInterleaved {
                out.append(Pair(l: planes[0][frame * 2], r: planes[0][frame * 2 + 1]))
            } else {
                out.append(Pair(l: planes[0][frame], r: planes[1][frame]))
            }
        }
        return out
    }

    // MARK: - The bug

    /// Reproduces what the phone actually did: an interleaved format written
    /// through the planar idiom `dst[channel][frame]`.
    ///
    /// On an interleaved buffer the two channel pointers are 2 bytes apart, so
    /// writing L[f] then R[f] then L[f+1] means R[f] is overwritten by L[f+1]
    /// before it is ever read. Kept as an executable statement of the defect:
    /// if this ever stops failing, the premise of the fix has changed.
    func testWritingAnInterleavedBufferWithThePlanarIdiomScramblesTheChannels() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 48_000,
                                   channels: 2,
                                   interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let dst = buffer.int16ChannelData!

        // The old code, verbatim.
        for frame in 0..<frames {
            dst[0][frame] = left[frame]
            dst[1][frame] = right[frame]
        }

        let read = pairs(buffer)
        XCTAssertNotEqual(read[0].r, right[0],
                          "right channel should have been clobbered — if not, the premise changed")
        XCTAssertNotEqual(read.map { Int($0.l) }, left.map { Int($0) },
                          "left channel should not have survived intact either")
    }

    // MARK: - The fix

    /// Interleaved output must carry each (L, R) pair adjacent and intact.
    func testInterleavedOutputKeepsEveryPairIntact() {
        let buffer = makeBuffer(interleaved: true)
        SpeakerPCMWriter.fill(buffer, frames: frames,
                              interleaved: true, left: left, right: right)
        let read = pairs(buffer)
        for frame in 0..<frames {
            XCTAssertEqual(read[frame].l, left[frame], "frame \(frame) left")
            XCTAssertEqual(read[frame].r, right[frame], "frame \(frame) right")
        }
    }

    func testPlanarOutputKeepsEveryPairIntact() {
        let buffer = makeBuffer(interleaved: false)
        SpeakerPCMWriter.fill(buffer, frames: frames,
                              interleaved: false, left: left, right: right)
        let read = pairs(buffer)
        for frame in 0..<frames {
            XCTAssertEqual(read[frame].l, left[frame], "frame \(frame) left")
            XCTAssertEqual(read[frame].r, right[frame], "frame \(frame) right")
        }
    }

    /// The layout is not a detail the caller may assume: whichever format the
    /// engine actually hands back, the pairs have to survive. So this is
    /// asserted through `format.isInterleaved` rather than a remembered flag.
    func testWriterAgreesWithWhateverLayoutTheFormatReports() {
        for interleaved in [true, false] {
            let buffer = makeBuffer(interleaved: interleaved)
            XCTAssertEqual(buffer.format.isInterleaved, interleaved)
            SpeakerPCMWriter.fill(buffer, frames: frames,
                                  interleaved: buffer.format.isInterleaved,
                                  left: left, right: right)
            let read = pairs(buffer)
            for frame in 0..<frames {
                XCTAssertEqual(read[frame].l, left[frame], "interleaved=\(interleaved) frame \(frame) L")
                XCTAssertEqual(read[frame].r, right[frame], "interleaved=\(interleaved) frame \(frame) R")
            }
        }
    }

    /// A short tail must be silence, not stale samples from the previous
    /// packet — the caller hands over whatever the ring had, which is rarely
    /// exactly one packet.
    func testAShortSourceLeavesTheRemainderSilent() {
        let buffer = makeBuffer(interleaved: false)
        SpeakerPCMWriter.fill(buffer, frames: frames, interleaved: false,
                              left: [1, 2], right: [3, 4])
        let read = pairs(buffer)
        XCTAssertEqual(read[0].l, 1)
        XCTAssertEqual(read[1].r, 4)
        XCTAssertEqual(read[2], Pair(l: 0, r: 0), "frame past the end of the source must be silent")
        XCTAssertEqual(read[3], Pair(l: 0, r: 0))
    }

    /// Silence must actually reach every channel. The old `memset` loop ran
    /// once per channel pointer, and on an interleaved buffer that is the same
    /// memory twice — harmless by luck — but it also cleared `frameCount`
    /// samples per plane, which overruns a shared plane.
    func testSilenceClearsEveryChannelAndNothingMore() {
        for interleaved in [true, false] {
            let buffer = makeBuffer(interleaved: interleaved)
            SpeakerPCMWriter.fill(buffer, frames: frames, interleaved: interleaved,
                                  left: left, right: right)
            SpeakerPCMWriter.silence(buffer, frames: frames, interleaved: interleaved)
            for (index, pair) in pairs(buffer).enumerated() {
                XCTAssertEqual(pair.l, 0, "interleaved=\(interleaved) frame \(index) L")
                XCTAssertEqual(pair.r, 0, "interleaved=\(interleaved) frame \(index) R")
            }
        }
    }

    /// Silence followed by a fill must not leak the previous packet back in.
    func testAPacketBoundaryDoesNotBleed() {
        let buffer = makeBuffer(interleaved: false)
        SpeakerPCMWriter.fill(buffer, frames: frames, interleaved: false,
                              left: [1, 2, 3, 4], right: [5, 6, 7, 8])
        // A packet with only 2 frames, after a silent gap.
        SpeakerPCMWriter.silence(buffer, frames: frames, interleaved: false)
        SpeakerPCMWriter.fill(buffer, frames: frames, interleaved: false,
                              left: [11, 12], right: [13, 14])
        let read = pairs(buffer)
        XCTAssertEqual(read[0], Pair(l: 11, r: 13))
        XCTAssertEqual(read[1], Pair(l: 12, r: 14))
        XCTAssertEqual(read[2], Pair(l: 0, r: 0), "stale audio from the previous packet")
        XCTAssertEqual(read[3], Pair(l: 0, r: 0), "stale audio from the previous packet")
    }
}