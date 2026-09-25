//! H.264 decoding via Cisco's OpenH264 (bundled, no system FFmpeg).
//!
//! The iOS encoder sends raw NAL units (AVCC, no start codes) split across
//! `sps` / `pps` / `video` frames. OpenH264 wants **Annex-B** (start codes)
//! and needs the SPS/PPS to arrive before the first slice — which matches
//! the iOS send order.

use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

/// An RGBA frame ready to blit into a window buffer (`0x00RRGGBB`).
#[derive(Debug, Clone)]
pub struct RgbaFrame {
    pub width: u32,
    pub height: u32,
    /// `width * height` pixels, `0x00RRGGBB`.
    pub pixels: Vec<u32>,
}

pub struct H264PreviewDecoder {
    decoder: Decoder,
    width: u32,
    height: u32,
}

impl H264PreviewDecoder {
    pub fn new() -> Result<Self, openh264::Error> {
        Ok(H264PreviewDecoder {
            decoder: Decoder::new()?,
            width: 0,
            height: 0,
        })
    }

    /// Feed one NAL unit and return a frame if one was produced.
    ///
    /// `nal` is the raw NAL payload (no length prefix, no start code). We
    /// wrap it in an Annex-B start code for OpenH264.
    pub fn feed_nal(&mut self, nal: &[u8]) -> Option<RgbaFrame> {
        if nal.is_empty() {
            return None;
        }
        let mut annexb = Vec::with_capacity(nal.len() + 4);
        annexb.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        annexb.extend_from_slice(nal);

        let yuv = self.decoder.decode(&annexb).ok()??;
        let (w, h) = yuv.dimensions();

        // Use the decoder's own converter (handles strides + SIMD).
        let mut rgba = vec![0u8; w * h * 4];
        yuv.write_rgba8(&mut rgba);

        // Repack RGBA bytes into the `0x00RRGGBB` words `minifb` wants.
        let mut pixels = Vec::with_capacity(w * h);
        for chunk in rgba.chunks_exact(4) {
            pixels.push(
                ((chunk[0] as u32) << 16) | ((chunk[1] as u32) << 8) | (chunk[2] as u32),
            );
        }

        self.width = w as u32;
        self.height = h as u32;
        Some(RgbaFrame {
            width: w as u32,
            height: h as u32,
            pixels,
        })
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }
}
