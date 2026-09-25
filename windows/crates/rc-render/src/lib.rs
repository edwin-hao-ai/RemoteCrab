//! `rc-render` — show the live iPhone video on Windows.
//!
//! H.264 decoding is done in Rust with Cisco's OpenH264 (bundled — no
//! system FFmpeg, no Media Foundation COM). Decoded frames are blitted to a
//! `minifb` window. The decoder is pure logic and has unit tests; the window
//! is a thin shell so the pipeline stays testable headlessly.

pub mod decoder;
#[cfg(not(test))]
pub mod window;

pub use decoder::{H264PreviewDecoder, RgbaFrame};

use rc_protocol::{NalFrame, NalKind};

/// Stateful NAL → frame bridge. Keeps the most recent decoded frame so the
/// window can redraw at its own pace.
pub struct PreviewPipeline {
    decoder: H264PreviewDecoder,
    latest: Option<RgbaFrame>,
    frames: u64,
}

impl PreviewPipeline {
    pub fn new() -> Result<Self, openh264::Error> {
        Ok(PreviewPipeline {
            decoder: H264PreviewDecoder::new()?,
            latest: None,
            frames: 0,
        })
    }

    /// Feed one video NAL. Returns true when a new frame was produced.
    pub fn push(&mut self, nal: &NalFrame) -> bool {
        match nal.kind {
            NalKind::Video | NalKind::Sps | NalKind::Pps => {}
        }
        if let Some(frame) = self.decoder.feed_nal(&nal.data) {
            self.latest = Some(frame);
            self.frames += 1;
            true
        } else {
            false
        }
    }

    pub fn latest(&self) -> Option<&RgbaFrame> {
        self.latest.as_ref()
    }

    pub fn frames_decoded(&self) -> u64 {
        self.frames
    }

    pub fn dimensions(&self) -> (u32, u32) {
        self.decoder.dimensions()
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
