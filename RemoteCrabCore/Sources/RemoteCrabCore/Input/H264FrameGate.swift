import Foundation

/// Decides which H.264 NAL units may be handed to a `VTDecompressionSession`
/// as a sample, and in what order.
///
/// Two rules, both learned from the receiver's "video decoded but recording
/// never starts" bug (the decoder died on the iPhone stream's first frame):
///
/// 1. **VCL slices only.** The wire carries one NAL per frame. Parameter
///    sets (7/8), SEI (6), AUD (9) and friends are not samples on their own;
///    feeding one makes VideoToolbox report `kVTVideoDecoderMalfunctionErr`
///    (`-12909`). The iOS encoder already strips them, so this is a guard
///    against older/future peers.
/// 2. **No P-slice before the first keyframe.** A non-IDR slice has no
///    reference pictures yet and also trips `-12909`. Drop it and wait for
///    the periodic IDR (the encoder emits one about once a second) instead
///    of killing the session.
///
/// Pure and platform-free so the receiver's decode loop can be unit-tested.
public struct H264FrameGate: Equatable {
    /// A keyframe has been accepted since the last `reset()`.
    public private(set) var sawKeyframe = false

    public init() {}

    /// Classify one NAL unit.
    public enum Decision: Equatable {
        /// Hand the NAL to VideoToolbox.
        case decode
        /// Not a VCL slice — silently ignore.
        case dropNonVCL
        /// P-slice with no reference keyframe yet — drop until the IDR.
        case dropBeforeKeyframe
    }

    /// Feed the NAL header byte (`nal[0]`); returns what to do with it.
    public mutating func classify(nalHeader: UInt8) -> Decision {
        let nalType = nalHeader & 0x1F
        guard nalType == 1 || nalType == 5 else { return .dropNonVCL }
        if nalType == 5 {
            sawKeyframe = true
            return .decode
        }
        return sawKeyframe ? .decode : .dropBeforeKeyframe
    }

    /// Forget the keyframe state — call when the decoder session is torn
    /// down and rebuilt, so post-rebuild P-slices wait for a fresh IDR.
    public mutating func reset() {
        sawKeyframe = false
    }
}
