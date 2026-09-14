import Foundation

/// Length-prefixed binary wire protocol used between RemoteCrabCapture
/// (iOS) and RemoteCrabReceiver (macOS) over a Bonjour-discovered TCP
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
        case featureControl = 0x07   // JSON FeatureControl (Mac → iPhone)
        case featureState  = 0x08    // JSON FeatureStateSnapshot (iPhone → Mac)
        case ping          = 0x09    // 8-byte BE timestampMicros, echoed verbatim
        case clientHello   = 0x0A    // JSON IBClientHello (Mac → iPhone)
        case sessionReply  = 0x0B    // JSON IBSessionReply (iPhone → Mac)
        case appList       = 0x0C    // JSON IBAppList (Mac → iPhone)
        case appListRequest = 0x0D   // JSON IBAppListRequest (iPhone → Mac)
        case activateApp   = 0x0E    // JSON IBActivateApp (iPhone → Mac)
        case fileOffer     = 0x0F    // JSON IBFileOffer (iPhone → Mac)
        case fileChunk     = 0x10    // raw bytes (iPhone → Mac)
        case fileComplete  = 0x11    // JSON IBFileComplete (iPhone → Mac)
        case fileAck       = 0x12    // JSON IBFileAck (Mac → iPhone)
        case clipboardSet  = 0x13    // JSON IBClipboard (either direction)
        case textCommand   = 0x14    // JSON IBTextCommandMessage (iPhone → Mac)
        case cameraCommand = 0x15    // JSON IBCameraCommand (Mac → iPhone)
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

    /// Encode a FeatureControl (Mac → iPhone remote toggle).
    public static func encode(featureControl: FeatureControl) throws -> Data {
        let json = try JSONEncoder().encode(featureControl)
        return encodeFrame(kind: .featureControl, payload: json)
    }

    /// Encode a FeatureStateSnapshot (iPhone → Mac state sync).
    public static func encode(featureState: FeatureStateSnapshot) throws -> Data {
        let json = try JSONEncoder().encode(featureState)
        return encodeFrame(kind: .featureState, payload: json)
    }

    /// Encode a ping frame. Payload is the 8-byte big-endian sender
    /// timestamp in microseconds; the iPhone echoes it back verbatim
    /// so the Mac can compute a real RTT.
    public static func encodePing(sentMicros: UInt64) -> Data {
        var payload = Data(capacity: 8)
        for shift in stride(from: 56, through: 0, by: -8) {
            payload.append(UInt8((sentMicros >> UInt64(shift)) & 0xFF))
        }
        return encodeFrame(kind: .ping, payload: payload)
    }

    /// Encode a ClientHello (Mac → iPhone identity handshake).
    public static func encode(clientHello: IBClientHello) throws -> Data {
        let json = try JSONEncoder().encode(clientHello)
        return encodeFrame(kind: .clientHello, payload: json)
    }

    /// Encode a SessionReply (iPhone → Mac ownership decision).
    public static func encode(sessionReply: IBSessionReply) throws -> Data {
        let json = try JSONEncoder().encode(sessionReply)
        return encodeFrame(kind: .sessionReply, payload: json)
    }

    /// Encode an app list (Mac → iPhone).
    public static func encode(appList: IBAppList) throws -> Data {
        let json = try JSONEncoder().encode(appList)
        return encodeFrame(kind: .appList, payload: json)
    }

    /// Encode an app-list request (iPhone → Mac).
    public static func encode(appListRequest: IBAppListRequest) throws -> Data {
        let json = try JSONEncoder().encode(appListRequest)
        return encodeFrame(kind: .appListRequest, payload: json)
    }

    /// Encode an activate-app request (iPhone → Mac).
    public static func encode(activateApp: IBActivateApp) throws -> Data {
        let json = try JSONEncoder().encode(activateApp)
        return encodeFrame(kind: .activateApp, payload: json)
    }

    /// Encode a file offer (iPhone → Mac).
    public static func encode(fileOffer: IBFileOffer) throws -> Data {
        encodeFrame(kind: .fileOffer, payload: try JSONEncoder().encode(fileOffer))
    }

    /// Encode a raw file chunk (iPhone → Mac).
    public static func encodeFileChunk(_ data: Data) -> Data {
        encodeFrame(kind: .fileChunk, payload: data)
    }

    /// Encode a file-complete marker (iPhone → Mac).
    public static func encode(fileComplete: IBFileComplete) throws -> Data {
        encodeFrame(kind: .fileComplete, payload: try JSONEncoder().encode(fileComplete))
    }

    /// Encode a file transfer ack (Mac → iPhone).
    public static func encode(fileAck: IBFileAck) throws -> Data {
        encodeFrame(kind: .fileAck, payload: try JSONEncoder().encode(fileAck))
    }

    /// Encode a clipboard payload (either direction).
    public static func encode(clipboard: IBClipboard) throws -> Data {
        encodeFrame(kind: .clipboardSet, payload: try JSONEncoder().encode(clipboard))
    }

    /// Encode a text-command message (iPhone → Mac).
    public static func encode(textCommand: IBTextCommandMessage) throws -> Data {
        encodeFrame(kind: .textCommand, payload: try JSONEncoder().encode(textCommand))
    }

    /// Encode a camera-switch command (Mac → iPhone).
    public static func encode(cameraCommand: IBCameraCommand) throws -> Data {
        encodeFrame(kind: .cameraCommand, payload: try JSONEncoder().encode(cameraCommand))
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

    /// Decode a `.featureControl` frame's payload.
    public static func decodeFeatureControl(_ frame: Frame) throws -> FeatureControl {
        try JSONDecoder().decode(FeatureControl.self, from: frame.payload)
    }

    /// Decode a `.featureState` frame's payload.
    public static func decodeFeatureState(_ frame: Frame) throws -> FeatureStateSnapshot {
        try JSONDecoder().decode(FeatureStateSnapshot.self, from: frame.payload)
    }

    /// Decode a `.clientHello` frame's payload.
    public static func decodeClientHello(_ frame: Frame) throws -> IBClientHello {
        try JSONDecoder().decode(IBClientHello.self, from: frame.payload)
    }

    /// Decode a `.sessionReply` frame's payload.
    public static func decodeSessionReply(_ frame: Frame) throws -> IBSessionReply {
        try JSONDecoder().decode(IBSessionReply.self, from: frame.payload)
    }

    /// Decode an `.appList` frame's payload.
    public static func decodeAppList(_ frame: Frame) throws -> IBAppList {
        try JSONDecoder().decode(IBAppList.self, from: frame.payload)
    }

    /// Decode an `.appListRequest` frame's payload.
    public static func decodeAppListRequest(_ frame: Frame) throws -> IBAppListRequest {
        try JSONDecoder().decode(IBAppListRequest.self, from: frame.payload)
    }

    /// Decode an `.activateApp` frame's payload.
    public static func decodeActivateApp(_ frame: Frame) throws -> IBActivateApp {
        try JSONDecoder().decode(IBActivateApp.self, from: frame.payload)
    }

    /// Decode a `.fileOffer` frame's payload.
    public static func decodeFileOffer(_ frame: Frame) throws -> IBFileOffer {
        try JSONDecoder().decode(IBFileOffer.self, from: frame.payload)
    }

    /// Decode a `.fileComplete` frame's payload.
    public static func decodeFileComplete(_ frame: Frame) throws -> IBFileComplete {
        try JSONDecoder().decode(IBFileComplete.self, from: frame.payload)
    }

    /// Decode a `.fileAck` frame's payload.
    public static func decodeFileAck(_ frame: Frame) throws -> IBFileAck {
        try JSONDecoder().decode(IBFileAck.self, from: frame.payload)
    }

    /// Decode a `.clipboardSet` frame's payload.
    public static func decodeClipboard(_ frame: Frame) throws -> IBClipboard {
        try JSONDecoder().decode(IBClipboard.self, from: frame.payload)
    }

    /// Decode a `.textCommand` frame's payload.
    public static func decodeTextCommand(_ frame: Frame) throws -> IBTextCommandMessage {
        try JSONDecoder().decode(IBTextCommandMessage.self, from: frame.payload)
    }

    /// Decode a `.cameraCommand` frame's payload.
    public static func decodeCameraCommand(_ frame: Frame) throws -> IBCameraCommand {
        try JSONDecoder().decode(IBCameraCommand.self, from: frame.payload)
    }

    /// Decode a `.ping` frame's payload into the sender timestamp.
    public static func decodePing(_ frame: Frame) -> UInt64 {
        var value: UInt64 = 0
        for byte in frame.payload.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
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