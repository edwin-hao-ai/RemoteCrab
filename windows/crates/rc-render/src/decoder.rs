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
    /// Why the last `feed_nal` produced nothing.
    ///
    /// `decode(..).ok()??` used to swallow this, which made "the phone sent no
    /// video at all" and "OpenH264 refused every NAL" look identical from the
    /// outside — both are just a counter stuck at zero, and the console prints
    /// the counter. A stream that silently never decodes is the most expensive
    /// thing to debug here, so the reason is kept.
    last_error: Option<String>,
    refused: u64,
    /// The most recent parameter sets, kept so they can be re-injected.
    ///
    /// This is not an optimisation. When OpenH264 hits a reference frame it
    /// cannot satisfy it calls `ResetDecoder()`, which **discards the SPS**, and
    /// then every following NAL fails with "no exist Sequence Parameter Sets
    /// ahead of sequence" — one bad frame kills the stream permanently.
    ///
    /// Measured on `docs/demo/remotecrab-demo.mp4`, which ffmpeg decodes as 721
    /// clean frames: OpenH264 refused 694 of its 728 NAL units, because the
    /// SPS declares `iNumRefFrames: 4`. One `PrefetchPic ERROR` at the first
    /// IDR, and the picture was dead for the rest of the file.
    ///
    /// Re-sending the parameter sets on the way back in turns that permanent
    /// death into a per-frame failure the decoder can recover from at the next
    /// keyframe. The phone only sends SPS/PPS once per session, so nothing
    /// upstream has to change for this to work.
    last_sps: Option<Vec<u8>>,
    last_pps: Option<Vec<u8>>,
    /// How many times the parameter sets have been re-sent, so a stream that
    /// cannot be decoded at all is visible as a number instead of as a silence.
    reinjected: u64,
}

impl H264PreviewDecoder {
    pub fn new() -> Result<Self, openh264::Error> {
        Self::with_config(openh264::decoder::DecoderConfig::new())
    }

    /// Same decoder, but with OpenH264's own tracing switched on.
    ///
    /// Its error return is a bare `16`, which names nothing. The trace goes to
    /// stderr from inside the C library and is the only thing that says *why*,
    /// so this exists for the case where the numeric code is not actionable.
    pub fn with_debug_tracing() -> Result<Self, openh264::Error> {
        Self::with_config(openh264::decoder::DecoderConfig::new().debug(true))
    }

    pub fn with_config(config: openh264::decoder::DecoderConfig) -> Result<Self, openh264::Error> {
        Ok(H264PreviewDecoder {
            decoder: Decoder::with_api_config(openh264::OpenH264API::from_source(), config)?,
            width: 0,
            height: 0,
            last_error: None,
            refused: 0,
            last_sps: None,
            last_pps: None,
            reinjected: 0,
        })
    }

    /// The parameter sets, and how many times they have been re-sent.
    ///
    /// A non-zero count on a healthy stream means the decoder keeps losing its
    /// SPS, which is the difference between "the picture has a glitch" and "the
    /// picture died and never came back".
    pub fn reinjections(&self) -> u64 {
        self.reinjected
    }

    /// Feed one NAL unit and return a frame if one was produced.
    ///
    /// `nal` is the raw NAL payload (no length prefix, no start code). We
    /// wrap it in an Annex-B start code for OpenH264.
    pub fn feed_nal(&mut self, nal: &[u8]) -> Option<RgbaFrame> {
        if nal.is_empty() {
            self.last_error = Some("empty NAL".into());
            return None;
        }
        // A NAL that begins with a 4-byte length is AVCC, not a raw unit.
        // Prepending a start code to that hands OpenH264 a length field where it
        // expects a NAL header, and it refuses every frame with no clue why.
        if looks_length_prefixed(nal) {
            self.refused += 1;
            self.last_error = Some(format!(
                "NAL is length-prefixed (AVCC), not a raw unit; first bytes {:02x?}",
                &nal[..nal.len().min(8)]
            ));
            return None;
        }

        // Remember the parameter sets before trying to decode anything with
        // them, so they survive a decoder reset.
        match nal.first().map(|b| b & 0x1F) {
            Some(7) => self.last_sps = Some(nal.to_vec()),
            Some(8) => self.last_pps = Some(nal.to_vec()),
            _ => {}
        }

        let frame = self.decode_one(nal);
        if frame.is_none() {
            // A refused slice leaves the decoder without an SPS, and it will
            // then refuse everything that follows for the same reason. Put the
            // parameter sets back and try once more — at the next keyframe this
            // is the difference between recovering and staying dead.
            if self.reinject_parameters() {
                return self.decode_one(nal);
            }
        }
        frame
    }

    /// Re-send the stored SPS and PPS. Returns whether anything was sent.
    fn reinject_parameters(&mut self) -> bool {
        let (Some(sps), Some(pps)) = (self.last_sps.clone(), self.last_pps.clone()) else {
            return false;
        };
        // Best effort: these are parameter sets, not pictures, so neither should
        // produce a frame. A failure here is not the caller's problem — the
        // retry of the real slice is.
        let _ = self.decode_one(&sps);
        let _ = self.decode_one(&pps);
        self.reinjected += 1;
        true
    }

    /// Prepend an Annex-B start code and hand the NAL to OpenH264.
    fn decode_one(&mut self, nal: &[u8]) -> Option<RgbaFrame> {
        if nal.is_empty() {
            self.last_error = Some("empty NAL".into());
            return None;
        }
        // A NAL that begins with a 4-byte length is AVCC, not a raw unit.
        // Prepending a start code to that hands OpenH264 a length field where it
        // expects a NAL header, and it refuses every frame with no clue why.
        if looks_length_prefixed(nal) {
            self.refused += 1;
            self.last_error = Some(format!(
                "NAL is length-prefixed (AVCC), not a raw unit; first bytes {:02x?}",
                &nal[..nal.len().min(8)]
            ));
            return None;
        }
        let mut annexb = Vec::with_capacity(nal.len() + 4);
        annexb.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        annexb.extend_from_slice(nal);

        let yuv = match self.decoder.decode(&annexb) {
            Ok(Some(yuv)) => yuv,
            Ok(None) => {
                // OpenH264's normal answer for a unit it is not ready to emit
                // yet (a slice without its reference, say). Counted, not blamed.
                self.last_error = None;
                return None;
            }
            Err(e) => {
                self.refused += 1;
                self.last_error = Some(format!("OpenH264 refused the NAL: {e}"));
                return None;
            }
        };
        let (w, h) = yuv.dimensions();
        self.last_error = None;

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

    /// NAL units this decoder refused, for any reason.
    pub fn refused(&self) -> u64 {
        self.refused
    }

    /// Why the most recent refusal happened, when there is a reason worth
    /// showing. `None` after a unit OpenH264 simply had no output for.
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }
}

/// Does this payload start with a 4-byte big-endian length that fits it?
///
/// That is the shape of AVCC, and no raw NAL has it: a NAL header byte is
/// `0x00` only for a reserved type, and the three bytes after it are not a
/// matching length. Getting this wrong is the difference between a stream that
/// decodes and one that never does, so it is a named function with tests.
fn looks_length_prefixed(nal: &[u8]) -> bool {
    if nal.len() < 9 {
        return false;
    }
    let len = u32::from_be_bytes([nal[0], nal[1], nal[2], nal[3]]) as usize;
    len == nal.len() - 4 || (len >= 4 && len + 4 <= nal.len())
}

impl RgbaFrame {
    /// Pack the frame into tightly-packed **BGRA** bytes — the layout the
    /// virtual-camera shared-memory ring (and Media Foundation `RGB32`)
    /// consumes. The alpha byte is forced opaque (`0xFF`) so consumers that
    /// honour alpha never see a transparent frame; `RgbaFrame` itself carries
    /// no alpha (`0x00RRGGBB`).
    pub fn to_bgra(&self) -> Vec<u8> {
        let mut out = vec![0xFFu8; self.pixels.len() * 4];
        for (dst, &p) in out.chunks_exact_mut(4).zip(self.pixels.iter()) {
            dst[0] = p as u8;
            dst[1] = (p >> 8) as u8;
            dst[2] = (p >> 16) as u8;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::{looks_length_prefixed, RgbaFrame};

    /// The failure this prevents: an AVCC blob handed to the Annex-B path,
    /// every frame refused, and a counter stuck at zero with nothing to read.
    #[test]
    fn a_length_prefixed_blob_is_recognised_as_avcc() {
        // 4-byte length, then exactly that many bytes: 0x67 = SPS.
        let payload: [u8; 5] = [0x67, 0x42, 0x00, 0x1F, 0xAA];
        let mut avcc = (payload.len() as u32).to_be_bytes().to_vec();
        avcc.extend_from_slice(&payload);
        assert_eq!(avcc.len(), 9);
        assert!(looks_length_prefixed(&avcc));

        // The common real shape: several NALs, so the first length covers only
        // the first one and does not span the buffer.
        let mut two = (payload.len() as u32).to_be_bytes().to_vec();
        two.extend_from_slice(&payload);
        two.extend_from_slice(&[0u8; 4]);
        two.extend_from_slice(&[0x65, 0x00, 0x00, 0x00, 0x01]);
        assert!(looks_length_prefixed(&two));
    }

    #[test]
    fn a_raw_nal_is_not_mistaken_for_a_length_prefix() {
        // An IDR slice: header 0x65 then arbitrary payload whose first four
        // bytes are 00 00 00 01 — a start code, not a length of the whole blob.
        let raw = [0x65u8, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE];
        assert!(!looks_length_prefixed(&raw));
        // Too short to carry a length at all.
        assert!(!looks_length_prefixed(&[0x67, 0x42]));
        assert!(!looks_length_prefixed(&[]));
    }

    #[test]
    fn to_bgra_reorders_channels_and_forces_opaque_alpha() {
        // 0x00RRGGBB: one red, one green, one blue pixel.
        let frame = RgbaFrame {
            width: 3,
            height: 1,
            pixels: vec![0x00FF_0000, 0x0000_FF00, 0x0000_00FF],
        };
        let bgra = frame.to_bgra();
        assert_eq!(bgra.len(), 12);
        assert_eq!(
            &bgra[0..4],
            &[0x00, 0x00, 0xFF, 0xFF],
            "red pixel is B,G,R,A"
        );
        assert_eq!(&bgra[4..8], &[0x00, 0xFF, 0x00, 0xFF]);
        assert_eq!(&bgra[8..12], &[0xFF, 0x00, 0x00, 0xFF]);
    }

    #[test]
    fn to_bgra_of_empty_frame_is_empty() {
        let frame = RgbaFrame {
            width: 0,
            height: 0,
            pixels: vec![],
        };
        assert!(frame.to_bgra().is_empty());
    }
}
