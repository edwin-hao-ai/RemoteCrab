//! Virtual-camera plumbing for the receiver.
//!
//! The heavy lifting lives in the `rc-vcam` crate (registration + session
//! camera) and the `rc-vcam-source` COM DLL (the `IMFMediaSource` consumers
//! activate). This module is the glue: it starts the camera and publishes
//! decoded frames into the shared-memory ring the DLL reads.
//!
//! Windows-only; `main.rs` gates every use behind `#[cfg(windows)]`.

use rc_render::RgbaFrame;

/// A running virtual camera plus the ring writer feeding it.
pub struct Vcam {
    camera: rc_vcam::VirtualCamera,
    writer: Option<rc_vcam::writer::FrameWriter>,
    frames: u64,
}

impl Vcam {
    /// Register the source DLL and start the session camera named `name`.
    ///
    /// Returns `None` (printing why) when the registration or the OS support
    /// check fails — the receiver keeps running without a virtual camera.
    pub fn start(name: &str) -> Option<Vcam> {
        if let Err(e) = rc_vcam::install_source() {
            eprintln!("  vcam: COM registration failed — {e}");
            return None;
        }
        match rc_vcam::start_camera(name) {
            Ok(camera) => {
                match camera.outcome() {
                    rc_vcam::StartOutcome::Started => println!(
                        "  vcam: \"{name}\" is live — choose it in the Camera app / Zoom / OBS"
                    ),
                    rc_vcam::StartOutcome::Failed => println!(
                        "  vcam: camera created but Start() failed — the source DLL could not be activated"
                    ),
                    rc_vcam::StartOutcome::Unsupported => println!(
                        "  vcam: this Windows build has no software-camera support (needs Windows 11 22H2+)"
                    ),
                }
                Some(Vcam {
                    camera,
                    writer: None,
                    frames: 0,
                })
            }
            Err(e) => {
                eprintln!("  vcam: {e}");
                None
            }
        }
    }

    /// Publish one decoded frame into the ring. The mapping is created on the
    /// first frame (the ring geometry then stays fixed for the session).
    ///
    /// `fps` is only a hint used for the header (sample timing lives in the
    /// COM source); 30 is a safe default.
    pub fn publish(&mut self, frame: &RgbaFrame, fps: u32) {
        if frame.width == 0 || frame.height == 0 {
            return;
        }
        let fps = fps.max(1);
        // Create the ring lazily. `source_dll_path` is where the COM server
        // lives, so a missing DLL is worth naming once, up front.
        if self.writer.is_none() {
            match rc_vcam::writer::FrameWriter::create(frame.width, frame.height, fps) {
                Ok(w) => self.writer = Some(w),
                Err(e) => {
                    eprintln!("  vcam: could not create the frame ring — {e}");
                    return;
                }
            }
        }
        let Some(writer) = self.writer.as_mut() else {
            return;
        };
        // A mid-stream resolution change cannot resize the existing mapping
        // (the DLL may already hold a view), so ignore the odd-sized frames.
        if writer.width() != frame.width || writer.height() != frame.height {
            return;
        }
        let bgra = frame.to_bgra();
        if writer.publish(&bgra).is_ok() {
            self.frames += 1;
        }
    }

    /// Frames handed to the ring so far (for logging).
    pub fn frames_written(&self) -> u64 {
        self.frames
    }
}

impl Drop for Vcam {
    fn drop(&mut self) {
        // Stop the session camera only. The CLSID registration is machine-wide
        // and inert on its own; removing it here would silently unregister the
        // camera whenever an elevated run exits, forcing elevation on every
        // subsequent start. `rc-vcam uninstall` is the explicit way out.
        self.camera.stop();
    }
}
