//! Pure BGRA→JPEG thumbnail encoding, shared by the window picker.
//!
//! Kept free of Win32 so the downscale + encode path can be unit-tested on
//! any host: the receiver grabs a window as a top-down 32-bit BGRA bitmap and
//! hands the bytes here, and we box-downsample to a small JPEG for the
//! iPhone's window cards (matching what the Mac sends).

use jpeg_encoder::{ColorType, Encoder};

/// Downscale a top-down 32-bit BGRA buffer so its longest edge is at most
/// `max_edge`, and encode it as JPEG. Returns `None` for empty input or an
/// encoder failure.
pub fn encode_bgra_jpeg(bgra: &[u8], width: u32, height: u32, max_edge: u32) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || max_edge == 0 {
        return None;
    }
    if bgra.len() < (width as usize) * (height as usize) * 4 {
        return None;
    }

    let scale = (max_edge as f64 / width.max(height) as f64).min(1.0);
    let tw = ((width as f64 * scale).round() as u32).max(1);
    let th = ((height as f64 * scale).round() as u32).max(1);

    let mut rgb = vec![0u8; (tw as usize) * (th as usize) * 3];
    for ty in 0..th {
        for tx in 0..tw {
            let sx0 = tx * width / tw;
            let sx1 = (((tx + 1) * width / tw).max(sx0 + 1)).min(width);
            let sy0 = ty * height / th;
            let sy1 = (((ty + 1) * height / th).max(sy0 + 1)).min(height);
            let (mut r, mut g, mut b, mut n) = (0u32, 0u32, 0u32, 0u32);
            for sy in sy0..sy1 {
                for sx in sx0..sx1 {
                    let i = ((sy * width + sx) * 4) as usize;
                    b += bgra[i] as u32;
                    g += bgra[i + 1] as u32;
                    r += bgra[i + 2] as u32;
                    n += 1;
                }
            }
            let n = n.max(1);
            let o = ((ty * tw + tx) * 3) as usize;
            rgb[o] = (r / n) as u8;
            rgb[o + 1] = (g / n) as u8;
            rgb[o + 2] = (b / n) as u8;
        }
    }

    let mut out = Vec::new();
    let encoder = Encoder::new(&mut out, 72);
    encoder.encode(&rgb, tw as u16, th as u16, ColorType::Rgb).ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny BGRA frame: left half red, right half blue.
    fn red_blue(width: u32, height: u32) -> Vec<u8> {
        let mut px = vec![0u8; (width * height * 4) as usize];
        for y in 0..height {
            for x in 0..width {
                let i = ((y * width + x) * 4) as usize;
                if x < width / 2 {
                    px[i] = 0; // B
                    px[i + 1] = 0; // G
                    px[i + 2] = 255; // R
                } else {
                    px[i] = 255;
                    px[i + 1] = 0;
                    px[i + 2] = 0;
                }
                px[i + 3] = 255;
            }
        }
        px
    }

    #[test]
    fn encodes_a_valid_jpeg() {
        let px = red_blue(64, 48);
        let jpeg = encode_bgra_jpeg(&px, 64, 48, 480).expect("encode");
        // JPEG SOI marker (FF D8) and EOI (FF D9).
        assert_eq!(&jpeg[..2], &[0xFF, 0xD8]);
        assert_eq!(&jpeg[jpeg.len() - 2..], &[0xFF, 0xD9]);
        assert!(jpeg.len() > 100);
    }

    #[test]
    fn downscales_to_the_max_edge() {
        let big = red_blue(1000, 500);
        let jpeg = encode_bgra_jpeg(&big, 1000, 500, 200).expect("encode");
        // Parse the SOF0 frame header to read back the encoded dimensions.
        // SOF0: FF C0, len(2), precision(1), height(2), width(2).
        let sof = jpeg
            .windows(2)
            .position(|w| w == [0xFF, 0xC0])
            .expect("SOF0");
        let height = u16::from_be_bytes([jpeg[sof + 5], jpeg[sof + 6]]);
        let width = u16::from_be_bytes([jpeg[sof + 7], jpeg[sof + 8]]);
        assert_eq!(width, 200);
        assert_eq!(height, 100);
    }

    #[test]
    fn rejects_empty_and_truncated_input() {
        assert!(encode_bgra_jpeg(&[], 0, 0, 100).is_none());
        assert!(encode_bgra_jpeg(&[0u8; 8], 64, 48, 100).is_none());
    }
}
