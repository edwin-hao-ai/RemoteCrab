//! `rc-mirror` — capture + H.264-encode a window for the app-window mirror,
//! plus the pure geometry/NAL helpers around it.
//!
//! The iPhone drives the mirror with `screenControl`/`screenInput` and the
//! receiver answers with `screenSps`/`screenPps`/`screenVideo` + `screenInfo`
//! — the same shapes the Mac receiver sends, so the phone's `ScreenShareView`
//! is unchanged. Everything that can be reasoned about without a screen lives
//! here and is unit-tested; the Win32 grab is `#[cfg(windows)]`.

// ---------------------------------------------------------------------------
// Annex-B / NAL helpers
// ---------------------------------------------------------------------------

/// Split an Annex-B byte stream into NAL payloads (start codes removed).
pub fn split_annex_b(data: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    let mut i = 0;
    while i + 3 <= data.len() {
        let three = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
        let four = i + 4 <= data.len()
            && data[i] == 0
            && data[i + 1] == 0
            && data[i + 2] == 0
            && data[i + 3] == 1;
        if three || four {
            if let Some(s) = start {
                let end = i - if four && i >= 1 && data[i - 1] == 0 { 1 } else { 0 };
                if end > s {
                    out.push(data[s..end].to_vec());
                }
            }
            i += if four { 4 } else { 3 };
            start = Some(i);
        } else {
            i += 1;
        }
    }
    if let Some(s) = start {
        if s < data.len() {
            out.push(data[s..].to_vec());
        }
    }
    out
}

/// H.264 NAL unit type (`nal[0] & 0x1F`), or 0 for an empty NAL.
pub fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1F).unwrap_or(0)
}

/// A NAL is a keyframe when it is an IDR slice (type 5).
pub fn is_keyframe(nal: &[u8]) -> bool {
    nal_type(nal) == 5
}

// ---------------------------------------------------------------------------
// Geometry / input mapping
// ---------------------------------------------------------------------------

/// The mirrored window's frame in screen points (what we put in `screenInfo`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Geometry {
    pub origin_x: f64,
    pub origin_y: f64,
    pub width: f64,
    pub height: f64,
}

impl Geometry {
    pub fn new(origin_x: f64, origin_y: f64, width: f64, height: f64) -> Self {
        Self {
            origin_x,
            origin_y,
            width,
            height,
        }
    }
}

/// Translate a normalized `(u, v)` inside the window to a screen point, the
/// inverse of what the phone does with its zoom/pan state. Values are clamped
/// to the window so a rounded edge can't land on the desktop behind it.
pub fn map_normalized(u: f32, v: f32, geo: &Geometry) -> (i32, i32) {
    let u = u.clamp(0.0, 1.0) as f64;
    let v = v.clamp(0.0, 1.0) as f64;
    let x = geo.origin_x + u * geo.width;
    let y = geo.origin_y + v * geo.height;
    (x.round() as i32, y.round() as i32)
}

/// Downscale `(width, height)` so the long edge is at most `max_edge`,
/// preserving aspect (never upscales). Returns at least 2×2 (H.264 needs
/// even dimensions).
pub fn fit_within(width: u32, height: u32, max_edge: u32) -> (u32, u32) {
    let long = width.max(height).max(1);
    if max_edge == 0 || long <= max_edge {
        return (width.max(2) & !1, height.max(2) & !1);
    }
    let scale = max_edge as f64 / long as f64;
    let w = ((width as f64 * scale).round() as u32).max(2) & !1;
    let h = ((height as f64 * scale).round() as u32).max(2) & !1;
    (w, h)
}

// ---------------------------------------------------------------------------
// H.264 encoder
// ---------------------------------------------------------------------------

use openh264::encoder::Encoder;
use openh264::formats::{RgbSliceU8, YUVBuffer};

/// Hardware-agnostic H.264 encoder wrapping OpenH264, fed top-down BGRA.
pub struct ScreenEncoder {
    inner: Encoder,
}

impl ScreenEncoder {
    pub fn new() -> Option<Self> {
        Encoder::new().ok().map(|inner| Self { inner })
    }

    /// Encode one top-down 32-bit BGRA frame; returns the NAL units in the
    /// encoded access unit (SPS/PPS/IDR/P…), start codes stripped.
    pub fn encode_bgra(&mut self, bgra: &[u8], width: u32, height: u32) -> Vec<Vec<u8>> {
        let (w, h) = (width as usize, height as usize);
        if bgra.len() < w * h * 4 || w == 0 || h == 0 {
            return Vec::new();
        }
        let mut rgb = vec![0u8; w * h * 3];
        for (i, px) in bgra.chunks_exact(4).enumerate() {
            rgb[i * 3] = px[2];
            rgb[i * 3 + 1] = px[1];
            rgb[i * 3 + 2] = px[0];
        }
        let yuv = YUVBuffer::from_rgb8_source(RgbSliceU8::new(&rgb, (w, h)));
        match self.inner.encode(&yuv) {
            Ok(bitstream) => split_annex_b(&bitstream.to_vec()),
            Err(_) => Vec::new(),
        }
    }
}

/// Box-downscale a top-down BGRA buffer.
pub fn downscale_bgra(src: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    let mut out = vec![0u8; (dw as usize) * (dh as usize) * 4];
    if sw == 0 || sh == 0 || dw == 0 || dh == 0 {
        return out;
    }
    for dy in 0..dh {
        let sy0 = dy * sh / dh;
        let sy1 = (((dy + 1) * sh / dh).max(sy0 + 1)).min(sh);
        for dx in 0..dw {
            let sx0 = dx * sw / dw;
            let sx1 = (((dx + 1) * sw / dw).max(sx0 + 1)).min(sw);
            let (mut b, mut g, mut r, mut a, mut n) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for sy in sy0..sy1 {
                for sx in sx0..sx1 {
                    let i = ((sy * sw + sx) * 4) as usize;
                    if i + 3 >= src.len() {
                        continue;
                    }
                    b += src[i] as u32;
                    g += src[i + 1] as u32;
                    r += src[i + 2] as u32;
                    a += src[i + 3] as u32;
                    n += 1;
                }
            }
            let n = n.max(1);
            let o = ((dy * dw + dx) * 4) as usize;
            out[o] = (b / n) as u8;
            out[o + 1] = (g / n) as u8;
            out[o + 2] = (r / n) as u8;
            out[o + 3] = (a / n) as u8;
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Capture (Windows)
// ---------------------------------------------------------------------------

/// A capturable top-level window.
#[cfg(windows)]
#[derive(Debug, Clone)]
pub struct WindowTarget {
    /// `"<pid>:<hwnd>"`, matching `WindowInfo.id`.
    pub id: String,
    pub app_id: String,
    pub app_name: String,
    pub title: String,
    pub geometry: Geometry,
}

/// Resolve a mirror target by `WindowInfo.id`, or the current foreground
/// window when `id` is `None`.
#[cfg(windows)]
pub fn resolve_target(id: Option<&str>) -> Option<WindowTarget> {
    let t = rc_os::windows::window_target(id)?;
    Some(WindowTarget {
        id: t.id,
        app_id: t.app_id,
        app_name: t.app_name,
        title: t.title,
        geometry: Geometry::new(t.origin_x, t.origin_y, t.width, t.height),
    })
}

/// Grab a window's pixels as top-down BGRA, downscaled so its long edge is at
/// most `max_edge`. Returns `(bgra, width, height)`.
#[cfg(windows)]
pub fn capture_bgra(id: &str, max_edge: u32) -> Option<(Vec<u8>, u32, u32)> {
    let (raw, sw, sh) = rc_os::windows::capture_window_bgra(id)?;
    let (dw, dh) = fit_within(sw, sh, max_edge);
    if (dw, dh) == (sw, sh) {
        Some((raw, sw, sh))
    } else {
        Some((downscale_bgra(&raw, sw, sh, dw, dh), dw, dh))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_three_and_four_byte_start_codes() {
        let data = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, // 4-byte
            0x00, 0x00, 0x01, 0x68, 0xBB, 0xCC, // 3-byte
            0x00, 0x00, 0x01, 0x65, 0xDD,
        ];
        let nals = split_annex_b(&data);
        assert_eq!(nals.len(), 3);
        assert_eq!(nals[0], vec![0x67, 0xAA]);
        assert_eq!(nals[1], vec![0x68, 0xBB, 0xCC]);
        assert_eq!(nals[2], vec![0x65, 0xDD]);
    }

    #[test]
    fn map_normalized_maps_and_clamps() {
        let geo = Geometry::new(100.0, 50.0, 200.0, 100.0);
        assert_eq!(map_normalized(0.0, 0.0, &geo), (100, 50));
        assert_eq!(map_normalized(1.0, 1.0, &geo), (300, 150));
        assert_eq!(map_normalized(0.5, 0.5, &geo), (200, 100));
        // Out-of-range clamps to the window edges.
        assert_eq!(map_normalized(2.0, -1.0, &geo), (300, 50));
    }

    #[test]
    fn fit_within_preserves_aspect_and_evenness() {
        assert_eq!(fit_within(1920, 1080, 1920), (1920, 1080));
        assert_eq!(fit_within(3840, 2160, 1920), (1920, 1080));
        assert_eq!(fit_within(1000, 800, 500), (500, 400));
        // Never upscales.
        assert_eq!(fit_within(640, 480, 1920), (640, 480));
        // Always even.
        let (w, h) = fit_within(1919, 1079, 1920);
        assert_eq!(w % 2, 0);
        assert_eq!(h % 2, 0);
    }

    #[test]
    fn encoder_produces_nals_for_a_synthetic_frame() {
        let Some(mut enc) = ScreenEncoder::new() else {
            return; // encoder unavailable in this environment
        };
        let (w, h) = (64u32, 48u32);
        let frame = vec![120u8; (w * h * 4) as usize];
        let nals = enc.encode_bgra(&frame, w, h);
        assert!(!nals.is_empty(), "encoder returned no NALs");
        // The first access unit should carry parameter sets + an IDR.
        assert!(
            nals.iter().any(|n| matches!(nal_type(n), 7 | 8 | 5)),
            "expected SPS/PPS/IDR, got {:?}",
            nals.iter().map(|n| nal_type(n)).collect::<Vec<_>>()
        );
    }
}
