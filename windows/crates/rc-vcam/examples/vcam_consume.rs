//! A **consumer-only** check of the virtual camera: open the camera the way
//! the Windows Camera app / Zoom / OBS do, and prove that the pixels coming
//! out of it change.
//!
//! ## Why this exists, when `vcam_probe` already passes
//!
//! `vcam_probe` is a closed loop. It creates the ring, registers the source,
//! starts the camera, publishes a test pattern **and then reads it back** — one
//! process on both ends. That genuinely proves the ring, the COM source, the
//! Frame Server activation and Media Foundation's sample delivery, and it is
//! the reason the bring-up got as far as it did.
//!
//! What it cannot prove is the one seam that matters for the product: that
//! **the receiver** publishes frames a real consumer can use. The producer in
//! that loop is the probe, so `rc-app`'s `Vcam::publish` — decoded iPhone
//! frame → BGRA → ring, plus the geometry negotiation when the phone changes
//! resolution — is never executed. A green `vcam_probe` says nothing about it,
//! and calling it the "E2E gate" (as the handoff doc did) is a claim the run
//! does not support.
//!
//! This probe is the other half. It never touches the ring: it does not create
//! a writer, does not register anything, does not start a camera. It only
//! enumerates video-capture devices through Media Foundation, finds ours, and
//! reads frames.
//!
//! ## How to use it
//!
//! Something else has to be the producer. Either the receiver with a real
//! phone:
//!
//! ```text
//! remotecrab.exe --connect <phone> --vcam --no-preview --no-tray
//! ```
//!
//! or the receiver's own test pattern, which needs no phone:
//!
//! ```text
//! remotecrab.exe --vcam-selftest
//! ```
//!
//! then, in another shell:
//!
//! ```text
//! cargo build --release --example vcam_consume -p rc-vcam
//! target\release\examples\vcam_consume.exe
//! ```
//!
//! Exit 0 means a real Media Foundation consumer received samples whose pixels
//! changed. That is everything a camera app needs, short of a person looking
//! at it.

#[cfg(not(windows))]
fn main() {
    eprintln!("vcam_consume is a Windows-only Media Foundation probe — nothing to do here.");
}

#[cfg(windows)]
use windows::core::PWSTR;
#[cfg(windows)]
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFMediaSource, MFCreateAttributes, MFCreateSourceReaderFromMediaSource,
    MFEnumDeviceSources, MFStartup, MFSTARTUP_FULL, MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
    MF_MT_FRAME_SIZE, MF_MT_SUBTYPE, MF_SOURCE_READER_FIRST_VIDEO_STREAM, MF_VERSION,
};
#[cfg(windows)]
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};

/// Frames to read. Twelve is enough to compare consecutive samples several
/// times over; a stream that is alive changes on every one of them.
#[cfg(windows)]
const READ_FRAMES: usize = 12;

/// How long to keep looking for the device. The camera only exists while the
/// producer's `MFCreateVirtualCamera` instance is alive, so a probe that starts
/// a moment too early has to keep looking rather than fail.
#[cfg(windows)]
const FIND_ATTEMPTS: u32 = 20;

/// Picks the RemoteCrab device out of the MF device enumeration, retrying.
///
/// The retry is not politeness: the frame server needs a beat after
/// `start_camera()` before the device shows up in the list.
#[cfg(windows)]
fn find_remote_crab() -> Option<IMFActivate> {
    // The whole probe is synchronous and single-threaded; wrapping the body
    // keeps the MF calls (raw out-pointers) in one auditable place.
    unsafe {
        for attempt in 1..=FIND_ATTEMPTS {
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
            let mut hit = None;
            let mut names = Vec::new();
            for i in 0..count as usize {
                // SAFETY: MFEnumDeviceSources allocated `count` entries here.
                let act = &*devices.add(i);
                let Some(a) = act else { continue };
                let mut pw = PWSTR::null();
                let mut len = 0u32;
                if a
                    .GetAllocatedString(&MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &mut pw, &mut len)
                    .is_err()
                {
                    continue;
                }
                let name = pw.to_string().unwrap_or_default();
                CoTaskMemFree(Some(pw.0 as *const _));
                names.push(name.clone());
                if name.contains("RemoteCrab") {
                    hit = Some(a.clone());
                }
            }
            let listed = if names.is_empty() {
                String::new()
            } else {
                format!(" — {}", names.join(", "))
            };
            println!("  attempt {attempt}: {count} capture device(s){listed}");
            if hit.is_some() {
                return hit;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        None
    }
}

#[cfg(windows)]
fn main() {
    use std::time::Instant;

    // The whole probe is synchronous and single-threaded; wrapping the body
    // keeps the MF calls (raw out-pointers) in one auditable place.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);

        println!("looking for the RemoteCrab camera — the producer must already be running…");
        let Some(act) = find_remote_crab() else {
            eprintln!(
                "RESULT: FAIL — RemoteCrab is not in the camera list.\n\
                 Is the producer running?  remotecrab.exe --vcam-selftest   (no phone needed)"
            );
            std::process::exit(1);
        };

        let source: IMFMediaSource = match act.ActivateObject() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("RESULT: FAIL — ActivateObject: {e:?}");
                std::process::exit(1);
            }
        };
        let reader = match MFCreateSourceReaderFromMediaSource(&source, None) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("RESULT: FAIL — MFCreateSourceReader: {e:?}");
                std::process::exit(1);
            }
        };

        // The geometry is read from the source rather than assumed, so this
        // also checks that what the producer published is what the consumer is
        // told — the negotiation that breaks silently when a phone changes
        // resolution mid-session.
        let mt = reader
            .GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32)
            .expect("GetCurrentMediaType");
        let sub = mt.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
        let size = mt.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
        let w = (size >> 32) as u32;
        let h = (size & 0xFFFF_FFFF) as u32;
        println!("  media type: {sub:?} {w}x{h}");
        if w == 0 || h == 0 {
            eprintln!("RESULT: FAIL — the source reports a zero-sized frame");
            std::process::exit(1);
        }

        let mut prev: Option<Vec<u8>> = None;
        let mut changed_total = 0usize;
        let mut samples = 0usize;
        let started = Instant::now();

        for n in 0..READ_FRAMES {
            let mut actual = 0u32;
            let mut flags = 0u32;
            let mut ts = 0i64;
            let mut sample = None;
            // Every out-parameter is passed: Media Foundation answers
            // E_POINTER (0x80004003) when one is `None`.
            if let Err(e) = reader.ReadSample(
                MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32,
                0,
                Some(&mut actual),
                Some(&mut flags),
                Some(&mut ts),
                Some(&mut sample),
            ) {
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
            match &prev {
                Some(p) => {
                    let d = p.iter().zip(bytes.iter()).filter(|(a, b)| a != b).count();
                    changed_total += d;
                    println!("  frame {n}: {} bytes, changed={d}", bytes.len());
                }
                None => println!("  frame {n}: {} bytes (first)", bytes.len()),
            }
            prev = Some(bytes);
        }

        println!(
            "  read {samples} samples in {:.1}s",
            started.elapsed().as_secs_f64()
        );

        if samples == 0 {
            eprintln!("RESULT: FAIL — no samples were delivered");
            std::process::exit(1);
        }
        if changed_total == 0 {
            eprintln!(
                "RESULT: FAIL — {samples} samples arrived but every frame was identical.\n\
                 The camera exists and Media Foundation is reading it, so this is a\n\
                 producer problem: nothing is advancing the ring."
            );
            std::process::exit(1);
        }
        println!("RESULT: PASS — a real MF consumer received {samples} samples with {changed_total} changing bytes");
    }
}