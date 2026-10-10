//! End-to-end check of Path A: play a known tone into the virtual audio cable
//! and capture it back from the cable's microphone endpoint.
//!
//! This is the whole chain the app relies on — play into the cable's render
//! endpoint, and any app can *record* it from the cable's capture endpoint —
//! proven without a phone. Run: `cargo run -p rc-audio --example cable_probe`.
//!
//! Exits 0 (`RESULT: PASS`) when the tone arrives, 1 otherwise.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

fn main() {
    let host = cpal::default_host();

    let cable = match rc_audio::pick_virtual_cable(&rc_audio::output_device_names()) {
        Some(c) => c,
        None => {
            println!("RESULT: SKIP - no virtual audio cable installed");
            std::process::exit(2);
        }
    };
    println!("cable render endpoint : {cable}");

    let capture = host
        .input_devices()
        .expect("input devices")
        .find(|d| d.to_string().to_lowercase().contains("cable output"));
    let Some(capture) = capture else {
        println!("RESULT: SKIP - the cable has no `CABLE Output` capture endpoint");
        std::process::exit(2);
    };
    println!("cable capture endpoint: {capture}");

    // --- play a 1 kHz tone into the cable's render endpoint ---
    let tone = host
        .output_devices()
        .expect("output devices")
        .find(|d| d.to_string() == cable)
        .expect("cable render device");
    let out_cfg = tone.default_output_config().expect("output config");
    let out_rate = out_cfg.sample_rate() as f32;
    let out_ch = out_cfg.channels() as usize;
    let phase = Arc::new(AtomicU32::new(0));
    let phase_w = phase.clone();
    let out_stream = tone
        .build_output_stream(
            out_cfg.config(),
            move |data: &mut [f32], _| {
                let mut p = f32::from_bits(phase_w.load(Ordering::Relaxed));
                for frame in data.chunks_mut(out_ch) {
                    let s = (p * std::f32::consts::TAU).sin() * 0.3;
                    p = (p + 1000.0 / out_rate).fract();
                    for x in frame.iter_mut() {
                        *x = s;
                    }
                }
                phase_w.store(p.to_bits(), Ordering::Relaxed);
            },
            |e| eprintln!("tone stream error: {e}"),
            None,
        )
        .expect("build tone stream");
    out_stream.play().expect("play tone");

    // --- capture from `CABLE Output` and watch for the tone ---
    let in_cfg = capture.default_input_config().expect("input config");
    if in_cfg.sample_format() != cpal::SampleFormat::F32 {
        println!(
            "RESULT: SKIP - capture format is {:?}, probe only reads F32",
            in_cfg.sample_format()
        );
        std::process::exit(2);
    }
    println!(
        "capturing from cable    : {} Hz, {} ch",
        in_cfg.sample_rate(),
        in_cfg.channels()
    );
    let peak = Arc::new(AtomicU32::new(0));
    let peak_w = peak.clone();
    let in_stream = capture
        .build_input_stream(
            in_cfg.config(),
            move |data: &[f32], _| {
                let p = data.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
                let prev = f32::from_bits(peak_w.load(Ordering::Relaxed));
                if p > prev {
                    peak_w.store(p.to_bits(), Ordering::Relaxed);
                }
            },
            |e| eprintln!("capture stream error: {e}"),
            None,
        )
        .expect("build capture stream");
    in_stream.play().expect("play capture");

    std::thread::sleep(Duration::from_millis(1500));
    let p = f32::from_bits(peak.load(Ordering::Relaxed));
    println!("peak at CABLE Output    : {p:.4}");
    if p > 0.02 {
        println!("RESULT: PASS - the cable carried the app's audio to its microphone");
        std::process::exit(0);
    }
    println!("RESULT: FAIL - silence at CABLE Output");
    std::process::exit(1);
}
