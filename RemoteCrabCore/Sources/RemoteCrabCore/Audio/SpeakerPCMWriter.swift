import AVFoundation
import Foundation

/// Fills an `AVAudioPCMBuffer` with stereo 16-bit samples, correctly for
/// **either** buffer layout.
///
/// This exists because the one caller declared an *interleaved* format and
/// then wrote through `int16ChannelData[channel][frame]`, which is the
/// **planar** idiom. For an interleaved buffer those two channel pointers are
/// 2 bytes apart, so `dst[1][0]` and `dst[0][1]` are the same address: every
/// right-channel sample was immediately overwritten by the next left-channel
/// sample. Measured on the device, that is one channel played at double speed
/// (pitch up — "shrill"), the other channel gone ("not clear"), and the
/// remaining samples forming L,R,L,R pairs that never existed ("noisy",
/// comb-filtered). The reported symptom list matched all three.
///
/// The rule, once: **index by frame, then by channel, only when planar.
/// When interleaved, index the single plane by `frame * channels + channel`.**
public enum SpeakerPCMWriter {

    /// Write `frames` samples per channel.
    ///
    /// - Parameters:
    ///   - left: `frames` samples, or fewer to leave the remainder silent.
    ///   - right: `frames` samples.
    public static func fill(_ buffer: AVAudioPCMBuffer,
                            frames: Int,
                            interleaved: Bool,
                            left: [Int16],
                            right: [Int16]) {
        guard let planes = buffer.int16ChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let count = min(frames, Int(buffer.frameLength))

        if interleaved {
            // One plane; L and R alternate.
            let plane = planes[0]
            for frame in 0..<count {
                let base = frame * channels
                for channel in 0..<channels {
                    plane[base + channel] = channel == 0
                        ? (frame < left.count ? left[frame] : 0)
                        : (channel == 1 ? (frame < right.count ? right[frame] : 0) : 0)
                }
            }
        } else {
            // One plane per channel, each contiguous.
            for channel in 0..<channels {
                let plane = planes[channel]
                let source = channel == 0 ? left : (channel == 1 ? right : [])
                for frame in 0..<count {
                    plane[frame] = frame < source.count ? source[frame] : 0
                }
            }
        }
    }

    /// Zero `frames` samples per channel, correctly for either layout.
    public static func silence(_ buffer: AVAudioPCMBuffer,
                              frames: Int,
                              interleaved: Bool) {
        guard let planes = buffer.int16ChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let count = min(frames, Int(buffer.frameLength))
        if interleaved {
            planes[0].update(repeating: 0, count: count * channels)
        } else {
            for channel in 0..<channels {
                planes[channel].update(repeating: 0, count: count)
            }
        }
    }
}