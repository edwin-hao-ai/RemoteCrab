//! `rc-render` — show the live iPhone video on Windows.
//!
//! H.264 decoding is done in Rust with Cisco's OpenH264 (bundled — no
//! system FFmpeg, no Media Foundation COM). Decoded frames are blitted to a
//! `minifb` window. The decoder is pure logic and has unit tests; the window
//! is a thin shell so the pipeline stays testable headlessly.

pub mod decoder;
pub mod pixels;
// Not `#[cfg(not(test))]`. Nothing in here opens a window — `run_preview_window`
// is the only function that needs a display, and no test calls it — but the cfg
// meant `FrameSlot`, the piece the whole preview path hands frames through, had
// no test at all. A module excluded from its own test build cannot be verified.
pub mod window;

pub use decoder::{H264PreviewDecoder, RgbaFrame};
pub use window::FrameSlot;

use rc_protocol::{NalFrame, NalKind};

/// Stateful NAL → frame bridge. Keeps the most recent decoded frame so the
/// window can redraw at its own pace.
pub struct PreviewPipeline {
    decoder: H264PreviewDecoder,
    latest: Option<std::sync::Arc<RgbaFrame>>,
    frames: u64,
    /// How many NALs were refused by the time the first frame came out.
    ///
    /// Every real stream starts with a handful the decoder cannot use — the
    /// leading pictures before the first IDR. Measured against a live iPhone:
    /// 22 refusals on a cold encoder, 9 on a warm one, then zero for the rest
    /// of the session. Left uncounted, a counter that always opens with "22
    /// refused" teaches whoever reads it next to ignore the number, which
    /// costs the counter its only job.
    warmup_refused: u64,
}

impl PreviewPipeline {
    pub fn new() -> Result<Self, openh264::Error> {
        Ok(PreviewPipeline {
            decoder: H264PreviewDecoder::new()?,
            latest: None,
            frames: 0,
            warmup_refused: 0,
        })
    }

    /// Feed one video NAL. Returns true when a new frame was produced.
    pub fn push(&mut self, nal: &NalFrame) -> bool {
        match nal.kind {
            NalKind::Video | NalKind::Sps | NalKind::Pps => {}
        }
        if let Some(frame) = self.decoder.feed_nal(&nal.data) {
            if self.frames == 0 {
                self.warmup_refused = self.decoder.refused();
            }
            self.latest = Some(std::sync::Arc::new(frame));
            self.frames += 1;
            true
        } else {
            false
        }
    }

    /// Borrowed view of the newest frame. Convenient for measuring or encoding
    /// it, where the frame is not outliving this call anyway.
    pub fn latest(&self) -> Option<&RgbaFrame> {
        self.latest.as_deref()
    }

    /// An owned handle to the newest frame, cheap to clone.
    ///
    /// This is the one the live path wants. Handing the frame to both the
    /// preview window and the virtual camera used to mean two deep copies of a
    /// `width * height * 4` buffer — 8.3 MB at 1080x1920, per frame, per
    /// consumer. A `clone()` on the `Arc` is a refcount bump, so both consumers
    /// read the exact buffer the decoder just produced and nothing is copied.
    pub fn latest_shared(&self) -> Option<std::sync::Arc<RgbaFrame>> {
        self.latest.clone()
    }

    pub fn frames_decoded(&self) -> u64 {
        self.frames
    }

pub fn dimensions(&self) -> (u32, u32) {
            self.decoder.dimensions()
        }

        /// NAL units the decoder refused, and why the last one was refused.
        ///
        /// Without these, a stream that never decodes is indistinguishable from
        /// a stream that never arrives: both report `frames_decoded() == 0`.
        pub fn refused(&self) -> u64 {
            self.decoder.refused()
        }

        pub fn last_error(&self) -> Option<&str> {
            self.decoder.last_error()
        }

        /// Refusals that happened before the stream produced anything — the
        /// leading pictures no decoder can turn into a frame.
        pub fn warmup_refusals(&self) -> u64 {
            self.warmup_refused
        }

        /// Refusals since the first frame, which is the number that means
        /// something is actually wrong.
        pub fn refusals_after_start(&self) -> u64 {
            self.decoder.refused().saturating_sub(self.warmup_refused)
        }
    }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pipeline_constructs() {
        let p = PreviewPipeline::new();
        assert!(p.is_ok(), "OpenH264 decoder should initialise");
    }

    #[test]
    fn empty_nal_is_ignored() {
        let mut p = PreviewPipeline::new().unwrap();
        let nal = NalFrame {
            kind: NalKind::Video,
            data: vec![],
            timestamp_micros: 0,
        };
        assert!(!p.push(&nal));
        assert_eq!(p.frames_decoded(), 0);
        assert!(p.latest().is_none());
    }

    #[test]
    fn bogus_nal_does_not_panic() {
        // A bogus NAL must not panic — OpenH264 errors are swallowed and we
        // simply wait for a real frame (robust against mid-stream joins).
        let mut p = PreviewPipeline::new().unwrap();
        let nal = NalFrame {
            kind: NalKind::Video,
            data: vec![0x41, 0xFF, 0x00, 0x12, 0x34],
            timestamp_micros: 0,
        };
        let _ = p.push(&nal);
        assert_eq!(p.frames_decoded(), 0);
    }
}
