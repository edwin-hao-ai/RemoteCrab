import XCTest
@testable import RemoteCrabCore

/// Round-trip tests for IBOpusEncoder / IBOpusDecoder (AudioConverter
/// Opus, 48 kHz mono). Opus is lossy, so assertions are on length,
/// energy and rough waveform shape — never on bit-exact samples.
final class IBOpusCodecTests: XCTestCase {

    // MARK: - helpers

    /// One 20 ms chunk (960 frames, Int16 mono) of a 440 Hz sine.
    private func sineChunk(amplitude: Double = 12_000, phaseOffset: Int = 0) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(960)
        for i in 0..<960 {
            let t = Double(i + phaseOffset) / 48_000.0
            samples.append(Int16(amplitude * sin(2 * .pi * 440 * t)))
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    /// One 20 ms chunk of a ~100 Hz square wave (harmonic-rich, stresses
    /// the codec differently from a pure tone).
    private func squareChunk(amplitude: Int16 = 10_000, phaseOffset: Int = 0) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(960)
        for i in 0..<960 {
            let phase = ((i + phaseOffset) % 480) < 240
            samples.append(phase ? amplitude : -amplitude)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func rms(_ pcm: Data) -> Double {
        guard !pcm.isEmpty else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for v in s { sum += Double(v) * Double(v) }
            sum /= Double(s.count)
        }
        return sum.squareRoot()
    }

    private func peak(_ pcm: Data) -> Int {
        var p = 0
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) {
                p = max(p, abs(Int(v)))
            }
        }
        return p
    }

    // MARK: - encoder

    func testEncoderRejectsNon48kSampleRate() {
        XCTAssertNil(IBOpusEncoder(sampleRate: 16_000))
        XCTAssertNil(IBOpusEncoder(sampleRate: 44_100))
        XCTAssertNotNil(IBOpusEncoder(sampleRate: 48_000))
    }

    func testEncodeProducesSmallPacket() throws {
        let encoder = try XCTUnwrap(IBOpusEncoder())
        // Feed a few chunks — the first may come back empty while the
        // codec holds priming frames.
        var packet: Data?
        for n in 0..<5 {
            if let out = encoder.encode(pcm: sineChunk(phaseOffset: n * 960)), !out.isEmpty {
                packet = out
                break
            }
        }
        let opus = try XCTUnwrap(packet, "encoder never produced a packet")
        // 24 kbps over 20 ms is 60 bytes; raw PCM would be 1920.
        XCTAssertLessThan(opus.count, 500)
        XCTAssertGreaterThan(opus.count, 0)
    }

    // MARK: - round trips

    func testSineRoundTrip() throws {
        let encoder = try XCTUnwrap(IBOpusEncoder())
        let decoder = try XCTUnwrap(IBOpusDecoder())

        let chunkCount = 50  // 1 second of audio
        var input = Data()
        var decoded = Data()
        for n in 0..<chunkCount {
            let chunk = sineChunk(phaseOffset: n * 960)
            input.append(chunk)
            guard let opus = encoder.encode(pcm: chunk), !opus.isEmpty else { continue }
            if let pcm = decoder.decode(packet: opus) {
                decoded.append(pcm)
            }
        }

        // Length: within ±1 packet (20 ms) of the input — priming and
        // codec lookahead may shift the tail by a frame or two.
        XCTAssertEqual(
            Double(decoded.count), Double(input.count),
            accuracy: Double(960 * 2 * 2),
            "decoded \(decoded.count) B vs input \(input.count) B"
        )

        // Signal survives: not silence, and roughly the same loudness.
        XCTAssertGreaterThan(peak(decoded), 0)
        let inRMS = rms(input), outRMS = rms(decoded)
        XCTAssertGreaterThan(inRMS, 0)
        XCTAssertEqual(outRMS, inRMS, accuracy: inRMS * 0.5,
                       "RMS in=\(inRMS) out=\(outRMS)")
        // Peak should be in the ballpark of the 12000 sine amplitude.
        XCTAssertEqual(Double(peak(decoded)), 12_000, accuracy: 6_000)
    }

    func testSquareWaveRoundTrip() throws {
        let encoder = try XCTUnwrap(IBOpusEncoder())
        let decoder = try XCTUnwrap(IBOpusDecoder())

        var input = Data()
        var decoded = Data()
        for n in 0..<50 {
            let chunk = squareChunk(phaseOffset: n * 960)
            input.append(chunk)
            guard let opus = encoder.encode(pcm: chunk), !opus.isEmpty else { continue }
            if let pcm = decoder.decode(packet: opus) {
                decoded.append(pcm)
            }
        }

        XCTAssertEqual(
            Double(decoded.count), Double(input.count),
            accuracy: Double(960 * 2 * 2)
        )
        XCTAssertGreaterThan(peak(decoded), 0)
        let inRMS = rms(input), outRMS = rms(decoded)
        XCTAssertEqual(outRMS, inRMS, accuracy: inRMS * 0.5,
                       "RMS in=\(inRMS) out=\(outRMS)")
    }

    // MARK: - decoder robustness

    func testDecoderSurvivesGarbagePacket() throws {
        let decoder = try XCTUnwrap(IBOpusDecoder())
        let garbage = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
        // Must not crash; nil (drop) or a best-effort decode both OK.
        _ = decoder.decode(packet: garbage)
        // A valid packet still decodes afterwards — one bad packet must
        // not poison the converter.
        let encoder = try XCTUnwrap(IBOpusEncoder())
        var opus: Data?
        for n in 0..<5 {
            if let out = encoder.encode(pcm: sineChunk(phaseOffset: n * 960)), !out.isEmpty {
                opus = out
                break
            }
        }
        let packet = try XCTUnwrap(opus)
        let pcm = decoder.decode(packet: packet)
        XCTAssertNotNil(pcm)
        XCTAssertGreaterThan(pcm?.count ?? 0, 0)
    }

    // MARK: - wire compatibility

    func testOpusPacketSurvivesWireRoundTrip() throws {
        let encoder = try XCTUnwrap(IBOpusEncoder())
        var opus: Data?
        for n in 0..<5 {
            if let out = encoder.encode(pcm: sineChunk(phaseOffset: n * 960)), !out.isEmpty {
                opus = out
                break
            }
        }
        let payload = try XCTUnwrap(opus)
        let packet = AudioPacket(
            opusData: payload, sampleRate: 48_000, channels: 1,
            timestampMicros: 20_000, codec: AudioPacket.codecOpus
        )
        let encoded = try IBWire.encode(audio: packet)
        let parser = IBWire.Parser()
        let frames = parser.append(encoded)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeAudio(frames[0])
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.codec, AudioPacket.codecOpus)
    }
}
