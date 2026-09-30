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

/// The one-shot jobs an elevated copy exists to do.
///
/// Run before the single-instance guard, so the process that is fixing or
/// removing the installation is never the one refused for being a second copy
/// of itself.
#[cfg(windows)]
pub fn run_elevated_job(install: bool) -> std::process::ExitCode {
    if install {
        return match rc_vcam::install_source() {
            Ok(()) => {
                println!("  vcam: {}", crate::i18n::t("已注册", "registered"));
                std::process::ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("  vcam: {e}");
                std::process::ExitCode::FAILURE
            }
        };
    }
    uninstall_elevated()
}

/// Remove everything, machine-wide bits included.
///
/// Split in two on purpose: the per-user half needs no rights and is done by
/// whoever ran the command, the machine half needs an administrator. Both
/// halves are idempotent, so running this twice is not an error.
#[cfg(windows)]
pub fn uninstall_elevated() -> std::process::ExitCode {
    let mut removed = rc_os::uninstall::remove_user_state();

    // Machine-wide: the COM registration and the NULL-DACL ring file. Both need
    // this process to be elevated, which is why this function is only ever
    // reached from the `runas` copy.
    removed.clsid = rc_vcam::uninstall_source().is_ok();
    removed.ring = rc_os::uninstall::remove_machine_files();

    if removed.is_complete() {
        println!("  {}", crate::i18n::t("已清理干净。", "Removed cleanly."));
        return std::process::ExitCode::SUCCESS;
    }
    eprintln!(
        "  {}",
        crate::i18n::t(
            "部分清理失败（COM 注册或 ring 文件）。请以管理员身份再运行一次。",
            "Some parts could not be removed (the COM registration or the ring file). \
             Run it once more as administrator.",
        )
    );
    std::process::ExitCode::FAILURE
}

/// Ask Windows to register the camera, elevating if that is what it takes.
///
/// The user's whole recovery is one UAC prompt. Nothing else is asked of them:
/// no terminal, no second binary, no registry instructions.
#[cfg(windows)]
pub fn install_with_elevation() -> crate::elevate::Elevation {
    // Already done? Then do not raise a prompt for nothing — the registration
    // is a machine-wide no-op after the first success, and a pointless UAC
    // prompt on every launch is how a product teaches users to click "Yes".
    if rc_vcam::install_source().is_ok() {
        return crate::elevate::Elevation::PromptAccepted;
    }
    crate::elevate::run_elevated("--install-vcam")
}

/// Is the camera registered? Drives whether the tray offers to install it.
#[cfg(windows)]
pub fn is_registered() -> bool {
    rc_vcam::install_source().is_ok()
}

impl Vcam {
    /// Register the source DLL and start the session camera named `name`.
    ///
    /// Returns `None` (printing why) when the registration or the OS support
    /// check fails — the receiver keeps running without a virtual camera.
    pub fn start(name: &str) -> Option<Vcam> {
        if let Err(e) = rc_vcam::install_source() {
            // The message must name the next action, not just the failure:
            // this line is the only place a user learns the camera is missing
            // before they go looking for it in the Camera app.
            if e.is_fixable_by_elevating() {
                eprintln!(
                    "  vcam: {} {}",
                    crate::i18n::t(
                        "未注册 — 在托盘菜单里点「安装虚拟摄像头」并允许管理员提示即可。",
                        "not registered — pick \"Install virtual camera\" in the tray menu and allow the administrator prompt."
                    ),
                    e
                );
            } else {
                eprintln!(
                    "  vcam: {} — {e}",
                    crate::i18n::t("COM 注册失败", "COM registration failed")
                );
            }
            return None;
        }
        match rc_vcam::start_camera(name) {
            Ok(camera) => {
                match camera.outcome() {
                    rc_vcam::StartOutcome::Started => println!(
                        "  vcam: \"{name}\" {}",
                        crate::i18n::t(
                            "已就绪 — 在相机应用 / Zoom / OBS 里选它",
                            "is live — choose it in the Camera app / Zoom / OBS"
                        )
                    ),
                    rc_vcam::StartOutcome::Failed => println!(
                        "  vcam: {}",
                        crate::i18n::t(
                            "虚拟摄像头已创建但 Start() 失败 — 源 DLL 无法被激活",
                            "camera created but Start() failed — the source DLL could not be activated"
                        )
                    ),
                    rc_vcam::StartOutcome::Unsupported => println!(
                        "  vcam: {}",
                        crate::i18n::t(
                            "这个 Windows 版本不支持软件摄像头（需要 Windows 11 22H2+）",
                            "this Windows build has no software-camera support (needs Windows 11 22H2+)"
                        )
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
                    eprintln!(
                        "  vcam: {} — {e}",
                        crate::i18n::t("无法创建帧共享环", "could not create the frame ring")
                    );
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
