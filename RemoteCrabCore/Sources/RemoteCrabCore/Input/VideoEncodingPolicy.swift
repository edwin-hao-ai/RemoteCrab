import Foundation

/// Encoder settings the phone derives from the capture format.
///
/// These lived as `private` code in `CaptureEngine.bitrateFor` and inline
/// literals in `H264Encoder.createSession`, so the two numbers that decide
/// picture quality could only be checked by reading the source.
public enum VideoEncodingPolicy {

    // MARK: - The property that actually decides the rate

    /// `kVTCompressionPropertyKey_Quality`, and on iOS it **overrides
    /// `kVTCompressionPropertyKey_AverageBitRate` entirely.**
    ///
    /// Measured on the same VideoToolbox encoder family
    /// (`scripts/vt-bitrate-probe.swift`, 1920x1080 @ 30fps over a synthetic
    /// high-detail scene, `AverageBitRate` held at 9,331,200):
    ///
    /// | Quality | achieved |
    /// |--------|----------|
    /// | 0.50   | 4,989 kbps |
    /// | 0.70   | 9,179 kbps |  ← what shipped
    /// | 0.75   | 10,886 kbps | ← this
    /// | 0.80   | 13,552 kbps |
    /// | 0.90   | 22,404 kbps |
    ///
    /// Asking for 6,220 kbps and for 9,331 kbps produced **byte-identical
    /// output** (3,442,273 bytes) — so the requested rate was not merely
    /// imprecise, it had no effect at all. A Windows machine with a real
    /// iPhone measured `6220 kbps` on the wire and read it as proof the
    /// coefficient was the lever; it was reading back the phone's own
    /// request.
    ///
    /// 0.75 buys ~19% more bits than the 0.70 that shipped, which is where
    /// the "preview looks soft / coloured speckle along edges" report is
    /// addressed. It is a single dial if a link ever needs more or less.
    public static let quality: Float = 0.75

    // MARK: - The requested rate (secondary on iOS)

    /// Bits per pixel per frame, asked for via `AverageBitRate`.
    ///
    /// **On iOS this is inert** — see `quality` above — so it is not what
    /// makes the picture sharp, and the figure the phone puts in
    /// `IBStreamMetadata` is a *request*, not a measurement. It is kept
    /// because it is the right target for any encoder that does honour it,
    /// and because the metadata field has always meant "the rate we asked
    /// for". Do not read a peer reporting 9,331 kbps as proof of a sharp
    /// picture; measure the pixels.
    ///
    /// 0.15 lands 1080x1920@30 at ~9.3 Mbps, which was the goal the Windows
    /// session measured against.
    public static let bitsPerPixel = 0.15

    /// Floor for tiny formats, so a low resolution never encodes at a rate
    /// that looks broken on any receiver.
    public static let floorBps = 1_000_000

    /// Ceiling on the *request*. It keeps a runaway format from asking for
    /// more than any receiver on a home network should carry — but note it
    /// is genuinely load-bearing at **1080p60**, a frame rate the app
    /// offers, which wants 18.66 Mbps. At 30 fps it does not bind at any
    /// offered resolution.
    public static let ceilingBps = 16_000_000

    /// Seconds between keyframes.
    ///
    /// Was `fps` — one I-frame per second. At 1080x1920 an I-frame is
    /// expensive, and paying for one every second left the other 29 P-frames
    /// almost nothing, which is what produced the *periodic* horizontal
    /// banding rather than uniform noise. This holds regardless of which
    /// property sets the rate: an I-frame is an I-frame.
    ///
    /// Two seconds does not add start-up latency: a fresh
    /// `VTCompressionSession` emits an IDR as its first frame regardless of
    /// this interval, and the phone only starts the encoder after the
    /// handshake grants it the session. The only cost is a decoder that
    /// joins a *running* stream waiting up to 2 s for a keyframe, which is
    /// why this is expressed in seconds and bounded by a test.
    public static let keyframeIntervalSeconds = 2

    /// The rate the phone asks the encoder for.
    public static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Int(Double(width * height * fps) * bitsPerPixel)
        return min(max(raw, floorBps), ceilingBps)
    }

    /// `kVTCompressionPropertyKey_MaxKeyFrameInterval` for a frame rate.
    public static func maxKeyFrameInterval(fps: Int) -> Int {
        max(1, fps) * keyframeIntervalSeconds
    }

    /// Bits actually produced per second, for comparing the encoder's
    /// behaviour against the rate it was asked for.
    ///
    /// This is the only measurement that can tell whether a request is being
    /// honoured, and on iOS it is what showed that it was not.
    public static func achievedBitsPerSecond(bytes: Int, seconds: Double) -> Int {
        guard seconds > 0, bytes > 0 else { return 0 }
        return Int(Double(bytes) * 8.0 / seconds)
    }
}