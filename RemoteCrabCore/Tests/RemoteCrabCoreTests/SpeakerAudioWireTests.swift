import XCTest
@testable import RemoteCrabCore

/// The "use the iPhone as the speaker" wire path: receiver → iPhone,
/// kind 0x24, PCM stereo.
///
/// The kind number itself is load-bearing in a way that is easy to miss:
/// an unregistered kind does not error, it falls through to a video NAL on
/// the receiving side (see `IBWire.encode(frame:)` and the Rust
/// `from_u8_or_video`), so a missing registration corrupts the camera
/// preview instead of failing loudly. These tests pin the number AND the
/// payload so a rename cannot slip through.
final class SpeakerAudioWireTests: XCTestCase {

    func testSpeakerAudioKindIs0x24() {
        // Frozen on the wire. 0x24 was the first free byte after
        // commandResult (0x23) when the feature was added.
        XCTAssertEqual(IBWire.Kind.speakerAudio.rawValue, 0x24)
    }

    func testNoKindCollidesWithSpeakerAudio() {
        let all = [IBWire.Kind.speakerAudio.rawValue]
        XCTAssertEqual(Set(all).count, all.count, "kind collision")
        XCTAssertNotEqual(IBWire.Kind.speakerAudio, IBWire.Kind.audio)
    }

    func testRoundTripsStereoPCM() throws {
        // 20 ms of 48 kHz stereo Int16 = 960 frames x 2 ch x 2 bytes.
        var samples = [Int16]()
        samples.reserveCapacity(960 * 2)
        for i in 0..<960 {
            let t = Double(i) / 48_000.0
            samples.append(Int16(12_000 * sin(2 * .pi * 440 * t)))
            samples.append(Int16(9_000 * sin(2 * .pi * 660 * t)))
        }
        let pcm = samples.withUnsafeBytes { Data($0) }

        let packet = AudioPacket(
            opusData: pcm,
            sampleRate: 48_000,
            channels: 2,
            timestampMicros: 1_234_567,
            codec: AudioPacket.codecPCM
        )

        let frame = try IBWire.encode(speakerAudio: packet)
        let parser = IBWire.Parser()
        let frames = parser.append(frame)
        XCTAssertEqual(frames.count, 1)
        let decoded = try IBWire.decodeSpeakerAudio(frames[0])

        XCTAssertEqual(decoded.codec, "pcm")
        XCTAssertEqual(decoded.channels, 2)
        XCTAssertEqual(decoded.sampleRate, 48_000)
        XCTAssertEqual(decoded.timestampMicros, 1_234_567)
        XCTAssertEqual(decoded.opusData, pcm, "PCM payload must survive base64 byte-for-byte")
    }

    /// The frame is large (3.8 KB of base64 for 20 ms), so it has to survive
    /// a partial write. This is the same incremental-parser path real audio
    /// takes, and the mic stream already depends on it.
    func testSurvivesFragmentedDelivery() throws {
        var samples = [Int16](repeating: 1_234, count: 960 * 2)
        let pcm = samples.withUnsafeBytes { Data($0) }
        samples.removeAll()

        let packet = AudioPacket(opusData: pcm, sampleRate: 48_000, channels: 2,
                                 timestampMicros: 42, codec: AudioPacket.codecPCM)
        let frame = try IBWire.encode(speakerAudio: packet)

        let parser = IBWire.Parser()
        var out: [IBWire.Frame] = []
        // Deliberately awkward chunking: 1 byte at a time, then the rest.
        for i in 0..<min(64, frame.count) {
            out += parser.append(Data(frame[i ..< i + 1]))
        }
        out += parser.append(Data(frame[64...]))
        XCTAssertEqual(out.count, 1, "a fragmented speaker frame must reassemble into exactly one frame")
        XCTAssertEqual(try IBWire.decodeSpeakerAudio(out[0]).opusData, pcm)
    }

    /// A phone that only knows kinds up to 0x23 must not be handed a
    /// speaker frame by mistake, and the sender must be able to say which
    /// kind it used without ambiguity.
    func testSpeakerAudioIsDistinctFromMicrophoneAudio() throws {
        var samples = [Int16](repeating: 42, count: 1920)
        let pcm = samples.withUnsafeBytes { Data($0) }
        samples.removeAll()

        let micFrame = try IBWire.encode(audio: AudioPacket(opusData: pcm, channels: 1))
        let speakerFrame = try IBWire.encode(
            speakerAudio: AudioPacket(opusData: pcm, channels: 2, codec: AudioPacket.codecPCM))

        let micKind = IBWire.Parser().append(micFrame)[0].kind
        let speakerKind = IBWire.Parser().append(speakerFrame)[0].kind
        XCTAssertEqual(micKind, .audio)
        XCTAssertEqual(speakerKind, .speakerAudio)
    }
}
