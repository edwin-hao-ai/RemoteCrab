import Foundation

/// Bonjour service type used by RemoteCrab. TCP variant because
/// the V0.1 wire format is length-prefixed binary — TCP avoids
/// the complexity of UDP packet reassembly for raw NAL units.
public enum IBServiceType {
    /// The DNS-SD service type advertised by RemoteCrabCapture.
    /// Always use this exact string for both publishing and browsing.
    public static let tcp = "_remotecrab._tcp"
    public static let domain = "local."
}

/// Connection / stream metadata exchanged at the start of every
/// V0.1 session.
///
/// Sent by RemoteCrabCapture as the first JSON message after a
/// connection is accepted; consumed by RemoteCrabReceiver to set up
/// the H.264 decoder and the preview window.
public struct IBStreamMetadata: Codable, Sendable, Equatable {

    public var version: Int
    public var deviceName: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateBps: Int
    public var codec: String          // "h264"
    public var sps: Data?             // H.264 SPS NAL unit
    public var pps: Data?             // H.264 PPS NAL unit

    public init(
        version: Int = 1,
        deviceName: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int,
        codec: String = "h264",
        sps: Data? = nil,
        pps: Data? = nil
    ) {
        self.version = version
        self.deviceName = deviceName
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateBps = bitrateBps
        self.codec = codec
        self.sps = sps
        self.pps = pps
    }

    /// Human-readable resolution label, e.g. "1080p".
    public var resolutionLabel: String {
        switch height {
        case 2160: return "4K"
        case 1440: return "1440p"
        case 1080: return "1080p"
        case 720:  return "720p"
        case 480:  return "480p"
        default:   return "\(width)x\(height)"
        }
    }
}

/// One H.264 video frame ready to ship over the wire.
public struct IBNalFrame: Sendable {
    public enum Kind: UInt8, Sendable {
        case video = 0x01
        case sps   = 0x02
        case pps   = 0x03
    }

    public let kind: Kind
    public let data: Data            // Annex-B NAL unit (with start code optional on the wire)
    public let timestampMicros: UInt64

    public init(kind: Kind, data: Data, timestampMicros: UInt64) {
        self.kind = kind
        self.data = data
        self.timestampMicros = timestampMicros
    }
}