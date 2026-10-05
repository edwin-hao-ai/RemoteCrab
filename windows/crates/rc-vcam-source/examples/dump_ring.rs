//! Write the newest virtual-camera frame to a PNG.
//!
//! The point is to be able to *look* at the picture. Everything else about this
//! pipeline is measured in counters — frames published, bytes mapped, samples
//! accepted by the Frame Server — and a counter cannot tell you that the image
//! is upside down, greyscale-channel-swapped, or a single flat colour. This is
//! the one step that needs eyes, and it should not need a phone.
//!
//! ```sh
//! # terminal 1: a fake iPhone streaming real H.264
//! cargo run -p rc-phone-sim --release -- --port 8765 --video 60
//! # terminal 2: the receiver, publishing into the ring the camera reads
//! remotecrab.exe --connect 127.0.0.1:8765 --vcam --no-tray
//! # terminal 3: look
//! cargo run -p rc-vcam-source --release --example dump_ring -- out.png
//! ```

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "ring.png".to_string());

    let Some(reader) = rc_vcam_source::ring::RingReader::open() else {
        eprintln!("no ring at {:?}", rc_vcam::shm::ring_file_path());
        eprintln!("start the receiver with --vcam first: it is what creates the ring");
        std::process::exit(1);
    };

    let Some((header, bgra)) = reader.latest_frame() else {
        eprintln!("the ring is empty — nothing has been published yet");
        std::process::exit(1);
    };

    let (w, h) = (header.width, header.height);
    println!("frame: {w}x{h}, stride {}, {} bytes", header.stride, bgra.len());

    // A flat frame is worth naming here rather than leaving to whoever opens the
    // file: it is the shape of "connected but nothing is arriving", and saying so
    // in the tool's own output is faster than squinting at a grey rectangle.
    let first = &bgra[..4.min(bgra.len())];
    let uniform = bgra.chunks_exact(4).all(|px| px == first);
    if uniform {
        println!("NOTE: every pixel is identical ({first:?}) — nothing is arriving");
    }

    let file = std::fs::File::create(&path).expect("create");
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().expect("write header");

    // The ring is BGRA. Swapping here rather than in the ring keeps the writer
    // (the hot path) doing a plain memcpy.
    let mut rgba = Vec::with_capacity(bgra.len());
    for px in bgra.chunks_exact(4) {
        rgba.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
    }
    writer.write_image_data(&rgba).expect("write image");
    println!("wrote {path}");
}
