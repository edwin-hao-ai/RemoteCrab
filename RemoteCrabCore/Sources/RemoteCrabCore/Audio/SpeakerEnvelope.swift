import Foundation

/// The coarse 0–9 picture of the speaker stream, one digit per packet.
///
/// It answers "is this a real signal or a flat line?", so it must be a function
/// of **one packet** and never of a running total. A cumulative average over
/// the capture converges to the loudest thing it has seen, so a gap between two
/// notes cannot appear in it at all — the long plateau this replaced was
/// arithmetic, not a missed gap.
///
/// The scale is `20 * log10` over the packet's RMS normalised by Int16 full
/// scale, mapped from -60 dBFS to 0 dBFS across nine steps. Normalising before
/// the log is what keeps it legible: `20 * log10(1958)` is +66 dB and every
/// audible packet would clip to 9.
public enum SpeakerEnvelope {

    /// Int16 full scale, the unit the capture path measures in.
    public static let fullScale: Double = 32_768

    /// The digit for one packet's RMS.
    public static func digit(packetRms: Double) -> Int {
        let normalised = max(packetRms / fullScale, 1e-6)
        let db = 20 * log10(normalised)
        return max(0, min(9, Int((db + 60) / 6)))
    }

    /// Digits for a run of packets, in order.
    public static func digits(forPacketRms packets: [Double]) -> [Int] {
        packets.map { digit(packetRms: $0) }
    }
}
