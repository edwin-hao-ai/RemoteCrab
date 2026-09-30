//! Self-contained end-to-end verification of the RemoteCrab virtual camera.
//!
//! This probe owns the whole pipeline in one process, so it needs no second
//! shell and no phone: it creates the shared-memory ring, registers the COM
//! source, starts a virtual camera, publishes a moving test pattern, then
//! opens the device through Media Foundation and reads real frames — asserting
//! that the pixels actually change between samples.
//!
//! Run:  cargo run --release -p rc-vcam --example vcam_probe
//!
//! The probe drives Media Foundation, so it is Windows-only. It used to break
//! `cargo test --workspace` and `cargo clippy --all-targets` on every other
//! platform before a single test ran — which is precisely the feedback loop
//! this repo needs on a Mac. A no-op `main` elsewhere keeps those commands
//! working everywhere; CI (`.github/workflows/windows.yml`) still builds and
//! runs the real probe on Windows.

#[cfg(not(windows))]
fn main() {
    eprintln!("vcam_probe is a Windows-only Media Foundation probe — nothing to do here.");
}

#[cfg(windows)]
fn main() {
    imp::main()
}

#[cfg(windows)]
mod imp {
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rc_vcam::shm;
use windows::core::PWSTR;
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFMediaSource, MFCreateAttributes, MFCreateSourceReaderFromMediaSource,
    MFEnumDeviceSources, MFStartup, MFSTARTUP_FULL, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
    MF_MT_FRAME_SIZE, MF_MT_SUBTYPE, MF_SOURCE_READER_FIRST_VIDEO_STREAM, MF_VERSION,
};
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};

const W: u32 = 1280;
const H: u32 = 720;
const FPS: u32 = 30;
const READ_FRAMES: usize = 12;

/// Picks the RemoteCrab device out of the MF device enumeration, retrying for
/// a few seconds: the frame server needs a beat after `start_camera()` before
/// the device shows up.
fn find_remote_crab() -> Option<IMFActivate> {
    // The whole probe is synchronous and single-threaded; wrapping the body
    // keeps the MF calls (raw out-pointers) in one auditable place.
    unsafe {
        for attempt in 0..30 {
            let mut attrs = None;
            if MFCreateAttributes(&mut attrs, 2).is_err() {
                return None;
            }
            let attrs = attrs?;
            if attrs
                .SetGUID(
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
                )
                .is_err()
            {
                return None;
            }
            let mut devices: *mut Option<IMFActivate> = std::ptr::null_mut();
            let mut count = 0u32;
            if MFEnumDeviceSources(&attrs, &mut devices, &mut count).is_err() {
                return None;
            }
            println!("  probe: attempt {attempt}: {count} video-capture device(s)");
            let mut hit = None;
            for i in 0..count as usize {
                // SAFETY: MFEnumDeviceSources allocated `count` entries here.
                let act = &*devices.add(i);
                let Some(a) = act else { continue };
                let mut pw = PWSTR::null();
                let mut len = 0u32;
                if a.GetAllocatedString(
                    &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
                    &mut pw,
                    &mut len,
                )
                .is_err()
                {
                    continue;
                }
                let name = pw.to_string().unwrap_or_default();
                CoTaskMemFree(Some(pw.0 as *const _));
                println!("    [{i}] \"{name}\"");
                if name.contains("RemoteCrab") {
                    hit = Some(a.clone());
                }
            }
            if hit.is_some() {
                return hit;
            }
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
        None
    }
}

pub fn main() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);

        // 1. Ring first: the COM source reads its geometry on activation.
        let mut writer = match rc_vcam::writer::FrameWriter::create(W, H, FPS) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("RESULT: FAIL — cannot create the frame ring: {e}");
                std::process::exit(1);
            }
        };

        // 2. COM source registration (idempotent; already-present key is fine).
        if let Err(e) = rc_vcam::install_source() {
            println!("  probe: install_source: {e} (continuing if already registered)");
        }

        // 3. Virtual camera instance. Kept alive for the whole probe.
        let camera = match rc_vcam::start_camera("RemoteCrab") {
            Ok(c) => c,
            Err(e) => {
                eprintln!("RESULT: FAIL — start_camera: {e}");
                std::process::exit(1);
            }
        };
        if !camera.is_started() {
            eprintln!(
                "RESULT: FAIL — Start() did not succeed ({:?})",
                camera.outcome()
            );
            std::process::exit(1);
        }

        // 4. Publish continuously on a background thread for the whole run.
        //    Media Foundation **discards samples with a duplicate timestamp**,
        //    so the ring must keep advancing while ReadSample blocks — feeding
        //    only before each read starves the reader.
        let stop = Arc::new(AtomicBool::new(false));
        let feeder = {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let mut frame_no: u64 = 0;
                while !stop.load(Ordering::Relaxed) {
                    let bgra = shm::test_pattern_bgra(W, H, frame_no);
                    if writer.publish(&bgra).is_err() {
                        break;
                    }
                    frame_no += 1;
                    std::thread::sleep(std::time::Duration::from_millis(1000 / FPS as u64));
                }
                frame_no
            })
        };
        // Let a few frames land before a consumer activates the source.
        std::thread::sleep(std::time::Duration::from_millis(500));

        // 5. Enumerate + open the device through Media Foundation.
        let Some(act) = find_remote_crab() else {
            camera.stop();
            eprintln!("RESULT: FAIL — RemoteCrab NOT FOUND in MF enumeration");
            std::process::exit(1);
        };
        let source: IMFMediaSource = match act.ActivateObject() {
            Ok(s) => s,
            Err(e) => {
                camera.stop();
                eprintln!("RESULT: FAIL — ActivateObject: {e:?}");
                std::process::exit(1);
            }
        };
        let reader = match MFCreateSourceReaderFromMediaSource(&source, None) {
            Ok(r) => r,
            Err(e) => {
                camera.stop();
                eprintln!("RESULT: FAIL — MFCreateSourceReader: {e:?}");
                std::process::exit(1);
            }
        };
        let mt = reader
            .GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32)
            .expect("GetCurrentMediaType");
        let sub = mt.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
        let size = mt.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
        let w = (size >> 32) as u32;
        let h = (size & 0xFFFF_FFFF) as u32;
        println!("current type: {sub:?} {w}x{h}");

        // 6. Read frames and count byte-level changes between consecutive ones.
        let mut prev: Option<Vec<u8>> = None;
        let mut changed_total = 0usize;
        let mut samples = 0usize;
        for n in 0..READ_FRAMES {
            let mut actual = 0u32;
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut sample = None;
            // Every out-parameter is passed: Media Foundation returns
            // E_POINTER (0x80004003) when they are `None`.
            if let Err(e) = reader.ReadSample(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                0,
                Some(&mut actual),
                Some(&mut flags),
                Some(&mut ts),
                Some(&mut sample),
            ) {
                camera.stop();
                eprintln!("RESULT: FAIL — ReadSample on frame {n}: {e:?}");
                std::process::exit(1);
            }
            let Some(s) = sample else {
                println!("  frame {n}: no sample (flags=0x{flags:x} ts={ts})");
                continue;
            };
            samples += 1;
            let buf = s.GetBufferByIndex(0).expect("GetBufferByIndex");
            let mut ptr = std::ptr::null_mut();
            let mut cur = 0u32;
            buf.Lock(&mut ptr, None, Some(&mut cur)).expect("Lock");
            let bytes = std::slice::from_raw_parts(ptr, cur as usize).to_vec();
            let _ = buf.Unlock();
            if let Some(p) = &prev {
                let d = p.iter().zip(bytes.iter()).filter(|(a, b)| a != b).count();
                changed_total += d;
                println!("  frame {n}: {} bytes, changed={d}", bytes.len());
            } else {
                println!("  frame {n}: {} bytes (first)", bytes.len());
            }
            prev = Some(bytes);
        }

        // 7. Tear down.
        stop.store(true, Ordering::Relaxed);
        let published = feeder.join().unwrap_or(0);
        camera.stop();
        println!("  published {published} frames into the ring");

        if samples == 0 {
            eprintln!("RESULT: FAIL — no samples were delivered");
            std::process::exit(1);
        }
        if changed_total == 0 {
            eprintln!("RESULT: FAIL — frames are static ({samples} samples)");
            std::process::exit(1);
        }
        println!(
            "RESULT: PASS — RemoteCrab delivered {samples} samples with {changed_total} changing bytes"
        );
    }
}
}
