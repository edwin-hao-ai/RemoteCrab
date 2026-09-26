//! Pure RGBA→PNG encoding for the app-launcher icons.
//!
//! Kept free of Win32 so the encode path can be unit-tested anywhere. The
//! Windows layer draws the process's `HICON` into a top-down 32-bit BGRA DIB
//! and hands the bytes here after converting to straight-alpha RGBA —
//! matching what the Mac receiver puts in `IBAppInfo.iconPNG` (128 px; we
//! render 48 px, iOS scales down cleanly).

/// Encode straight-alpha RGBA pixels as a PNG. Returns `None` on a size or
/// buffer mismatch, or an encoder failure.
pub fn encode_rgba_png(rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    if width == 0 || height == 0 {
        return None;
    }
    if rgba.len() != (width as usize) * (height as usize) * 4 {
        return None;
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
        writer.finish().ok()?;
    }
    Some(out)
}

/// Convert a top-down 32-bit BGRA buffer to RGBA (same length).
pub fn bgra_to_rgba(bgra: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; bgra.len()];
    for (src, dst) in bgra.chunks_exact(4).zip(out.chunks_exact_mut(4)) {
        dst[0] = src[2];
        dst[1] = src[1];
        dst[2] = src[0];
        dst[3] = src[3];
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A solid red pixel buffer.
    fn red(width: u32, height: u32) -> Vec<u8> {
        let mut px = vec![0u8; (width * height * 4) as usize];
        for chunk in px.chunks_exact_mut(4) {
            chunk[0] = 255; // R
            chunk[3] = 255; // A
        }
        px
    }

    #[test]
    fn encodes_valid_png_bytes() {
        let png = encode_rgba_png(&red(48, 48), 48, 48).expect("encode");
        // PNG signature + IHDR: bit 24-27 = width, 28-31 = height.
        assert_eq!(&png[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        let w = u32::from_be_bytes(png[16..20].try_into().unwrap());
        let h = u32::from_be_bytes(png[20..24].try_into().unwrap());
        assert_eq!((w, h), (48, 48));
        assert_eq!(&png[12..16], b"IHDR");
    }

    #[test]
    fn rejects_bad_input() {
        assert!(encode_rgba_png(&[], 0, 0).is_none());
        assert!(encode_rgba_png(&red(10, 10), 8, 10).is_none());
    }

    #[test]
    fn bgra_to_rgba_swaps_channels_and_keeps_alpha() {
        // BGRA: blue=255, alpha=64 → RGBA: red=255, alpha=64.
        let out = bgra_to_rgba(&[255, 0, 0, 64]);
        assert_eq!(out, vec![0, 0, 255, 64]);
    }
}
