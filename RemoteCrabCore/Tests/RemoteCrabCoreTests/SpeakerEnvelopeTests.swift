import XCTest
@testable import RemoteCrabCore

/// The envelope is a coarse 0–9 picture of what arrived, one digit per 20 ms
/// packet, and it exists to answer "is this a real signal or a flat line?".
///
/// It is fed **this packet's** RMS. That is the whole point of the type: a
/// running average over the whole capture converges to the level of whatever
/// is loudest and cannot represent a gap between two notes, so the silence it
/// was built to reveal is arithmetically unable to appear.
final class SpeakerEnvelopeTests: XCTestCase {

    /// Int16 full scale, the unit `enqueue` measures in.
    private let fullScale = 32_768.0

    func test_digital_silence_is_the_bottom_of_the_scale() {
        XCTAssertEqual(SpeakerEnvelope.digit(packetRms: 0), 0)
    }

    func test_full_scale_is_the_top_of_the_scale() {
        XCTAssertEqual(SpeakerEnvelope.digit(packetRms: fullScale), 9)
    }

    /// Averages over a real capture: conversation and music both sit far below
    /// full scale, and a scale that clips them all to 9 is a flat line with
    /// extra steps.
    ///
    /// The figures are derived, not measured: -24 dBFS is
    /// `(-24 + 60) / 6 = 6.0`, truncated to 5; -12 dBFS is `7.99`, truncated to
    /// 7. Truncation is why the top of each step is unreachable, and pinning it
    /// here is what stops someone "fixing" the scale by rounding.
    func test_ordinary_programme_levels_land_in_the_middle_of_the_scale() {
        XCTAssertEqual(SpeakerEnvelope.digit(packetRms: fullScale * 0.063), 5)  // ≈ -24 dBFS
        XCTAssertEqual(SpeakerEnvelope.digit(packetRms: fullScale * 0.25), 7)   // ≈ -12 dBFS
    }

    func test_the_scale_is_monotonic_and_never_leaves_its_range() {
        var previous = -1
        for step in 0...200 {
            let digit = SpeakerEnvelope.digit(packetRms: fullScale * Double(step) / 200)
            XCTAssertGreaterThanOrEqual(digit, 0)
            XCTAssertLessThanOrEqual(digit, 9)
            XCTAssertGreaterThanOrEqual(digit, previous, "not monotonic at step \(step)")
            previous = digit
        }
    }

    /// The regression this type was written for: a gap must read lower than the
    /// notes on either side of it. With a running average in place of this
    /// packet's level, all three digits were identical by construction.
    func test_a_gap_between_two_notes_reads_lower_than_either_note() {
        let note = fullScale * 0.25   // ≈ -12 dBFS
        let gap = 0.0

        let noteDigit = SpeakerEnvelope.digit(packetRms: note)
        let gapDigit = SpeakerEnvelope.digit(packetRms: gap)

        XCTAssertLessThan(gapDigit, noteDigit)
        XCTAssertEqual(gapDigit, 0)
    }

    /// The sequence the envelope is actually asked to draw: eight notes with
    /// gaps. The shape is the assertion the device e2e cannot make, so it is
    /// made here against the mapping instead.
    func test_eight_notes_with_gaps_have_a_shape() {
        let note = fullScale * 0.25
        let packets: [Double] = (0..<8).flatMap { _ in [note, note, 0, 0] }
        let digits = SpeakerEnvelope.digits(forPacketRms: packets)

        XCTAssertEqual(digits.count, packets.count)
        XCTAssertEqual(digits.filter { $0 == 0 }.count, 16, "every gap must be visible")
        XCTAssertGreaterThan(Set(digits).count, 1, "a flat line is exactly what this replaced")
    }
}
