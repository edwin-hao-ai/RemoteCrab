import Foundation

/// Length-prefixed binary wire protocol used between iBridgeCapture
/// (iOS) and iBridgeReceiver (macOS) over a Bonjour-discovered TCP
/// connection.
///
/// Frame format (host byte order — we encode big-endian explicitly):
///
/// ```
/// ┌──────────────────────────────────────────────────────────────────┐
/// │  [4 bytes BE length, includes 1-byte kind][1 byte kind][payload]  │
/// └──────────────────────────────────────────────────────────────────┘
/// ```
///
/// The first frame on every connection is a UTF-8 JSON
/// `IBStreamMetadata` message with the same length-prefix
/// framing (kind byte = 0x00 = `.metadata`).
public enum IBWire {

    public enum Kind: UInt8 {
        case metadata = 0x00
        case video    = 0x01
        case sps      = 0x02
        case pps      = 0x03
        case touch    = 0x04   // JSON TouchEvent
        case key      = 0x05   // JSON KeyEvent
        case audio    = 0x06   // JSON AudioPacket (opus data base64-encoded)
    }

    // MARK: - Encoding

    /// Encode a metadata message into the wire format.
    public static func encode(metadata: IBStreamMetadata) throws -> Data {
        let json = try JSONEncoder().encode(metadata)
        return encodeFrame(kind: .metadata, payload: json)
    }

    /// Encode a video / SPS / PPS NAL frame into the wire format.
    public static func encode(frame: IBNalFrame) -> Data {
        encodeFrame(kind: Kind(rawValue: frame.kind.rawValue) ?? .video,
                    payload: frame.data)
    }

    /// Encode a TouchEvent into the wire format.
    public static func encode(touch: TouchEvent) throws -> Data {
        let json = try JSONEncoder().encode(touch)
        return encodeFrame(kind: .touch, payload: json)
    }

    /// Encode a KeyEvent into the wire format.
    public static func encode(key: KeyEvent) throws -> Data {
        let json = try JSONEncoder().encode(key)
        return encodeFrame(kind: .key, payload: json)
    }

    /// Encode an AudioPacket into the wire format. The Opus payload is
    /// base64-encoded inside the JSON envelope so all frames share the
    /// same `Data` transport.
    public static func encode(audio: AudioPacket) throws -> Data {
        let json = try JSONEncoder().encode(audio)
        return encodeFrame(kind: .audio, payload: json)
    }

    /// Low-level: prepend length + kind byte to a payload.
    public static func encodeFrame(kind: Kind, payload: Data) -> Data {
        // length includes the 1-byte kind + payload
        let length = UInt32(1 + payload.count)
        var out = Data(capacity: 4 + Int(length))
        out.appendUInt32BE(length)
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    // MARK: - Decoding

    public struct Frame: Equatable {
        public let kind: Kind
        public let payload: Data
    }

    /// Incremental parser. Feed incoming bytes; receive zero or more
    /// complete frames back. Holds on to the trailing partial frame
    /// across calls so callers don't have to manage buffering.
    public final class Parser: @unchecked Sendable {

        private var buffer = Data()
        public private(set) var framesParsed: Int = 0

        public init() {}

        /// Append bytes and return any complete frames extracted.
        public func append(_ data: Data) -> [Frame] {
            buffer.append(data)
            var out: [Frame] = []
            while let frame = tryParseNext() {
                out.append(frame)
                framesParsed += 1
            }
            return out
        }

        public func reset() {
            buffer.removeAll(keepingCapacity: false)
            framesParsed = 0
        }

        private func tryParseNext() -> Frame? {
            // Need 4 bytes for the length header.
            guard buffer.count >= 4 else { return nil }

            let length = buffer.readUInt32BE(at: 0)
            guard length >= 1, length <= 64 * 1024 * 1024 else {
                // Refuse frames larger than 64 MiB — protects against
                // accidental infinite-loop from corrupt length values.
                buffer.removeAll()
                return nil
            }

            // Need length + 4 bytes total (header + payload).
            let total = 4 + Int(length)
            guard buffer.count >= total else { return nil }

            // Strip the 4-byte length header.
            buffer.removeFirst(4)

            let kindByte = buffer[buffer.startIndex]
            buffer.removeFirst()
            let payload = buffer.prefix(Int(length) - 1)
            buffer.removeFirst(Int(length) - 1)

            return Frame(
                kind: Kind(rawValue: kindByte) ?? .video,
                payload: Data(payload)
            )
        }
    }

    // MARK: - Decoded event helpers

    /// Decode a `.touch` frame's payload into a `TouchEvent`.
    public static func decodeTouch(_ frame: Frame) throws -> TouchEvent {
        try JSONDecoder().decode(TouchEvent.self, from: frame.payload)
    }

    /// Decode a `.key` frame's payload into a `KeyEvent`.
    public static func decodeKey(_ frame: Frame) throws -> KeyEvent {
        try JSONDecoder().decode(KeyEvent.self, from: frame.payload)
    }

    /// Decode an `.audio` frame's payload into an `AudioPacket`.
    public static func decodeAudio(_ frame: Frame) throws -> AudioPacket {
        try JSONDecoder().decode(AudioPacket.self, from: frame.payload)
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        // Write byte-by-byte to avoid alignment issues.
        self.append(UInt8((value >> 24) & 0xFF))
        self.append(UInt8((value >> 16) & 0xFF))
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        // Read byte-by-byte to avoid alignment traps on misaligned buffers.
        let b0 = UInt32(self[self.startIndex.advanced(by: offset)])
        let b1 = UInt32(self[self.startIndex.advanced(by: offset + 1)])
        let b2 = UInt32(self[self.startIndex.advanced(by: offset + 2)])
        let b3 = UInt32(self[self.startIndex.advanced(by: offset + 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}