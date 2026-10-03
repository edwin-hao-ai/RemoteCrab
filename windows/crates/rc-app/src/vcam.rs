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

/// The one-shot jobs: register, or clean up. Run before the single-instance
/// guard, so the process that is fixing or removing the installation is never
/// the one refused for being a second copy of itself.
///
/// Each of these raises its own UAC prompt when it needs one. The earlier
/// version assumed the caller had already arranged the elevation, which was true
/// for the tray and false for anyone typing the command — so a terminal user was
/// told to "approve the Windows prompt" for a window that never appeared, and
/// had no way forward. The whole point of the product is that nobody should have
/// to know what an administrator prompt is.
#[cfg(windows)]
pub fn run_one_shot(
    install: bool,
    machine_only: bool,
    user_only: bool,
) -> std::process::ExitCode {
    if install {
        return match install_with_elevation() {
            // The elevated copy prints its own result; Windows reports no exit
            // code for it, so "the prompt was accepted" is the strongest claim
            // available and the strongest we make.
            crate::elevate::Elevation::PromptAccepted => std::process::ExitCode::SUCCESS,
            crate::elevate::Elevation::Declined => {
                eprintln!(
                    "  {}",
                    crate::i18n::t(
                        "已取消 — 摄像头没有注册。",
                        "cancelled — the camera was not registered."
                    )
                );
                std::process::ExitCode::FAILURE
            }
            crate::elevate::Elevation::Unavailable => {
                eprintln!(
                    "  {}",
                    crate::i18n::t(
                        "无法弹出管理员提示（可能被系统策略阻止）。",
                        "could not raise the administrator prompt (a policy may be blocking it)."
                    )
                );
                std::process::ExitCode::FAILURE
            }
            crate::elevate::Elevation::AlreadyElevated => {
                // Name the real reason, because "already elevated" plus a
                // refusal is otherwise unexplainable to whoever has to fix it.
                let why = rc_vcam::install_source()
                    .err()
                    .map(|e| e.to_string())
                    .unwrap_or_else(|| "-".into());
                eprintln!(
                    "  {} {why}",
                    crate::i18n::t(
                        "注册失败，且已在管理员权限下运行。",
                        "registration failed, and this was already running as administrator."
                    )
                );
                std::process::ExitCode::FAILURE
            }
        };
    }
    if machine_only {
        return uninstall_machine_only();
    }
    if user_only {
        return report_removal(&rc_os::uninstall::remove_user_state());
    }
    uninstall_with_elevation()
}

/// Whether a one-shot job may still raise a UAC prompt.
///
/// The recursion guard, in one place: the elevated copy of `--uninstall-vcam`
/// runs the identical flag, so without this it would re-prompt forever.
#[cfg(windows)]
fn may_prompt() -> bool {
    !crate::elevate::is_elevated()
}

/// Remove everything, machine-wide bits included, prompting if that is what it
/// takes.
///
/// Split in two on purpose: the per-user half needs no rights and is done by
/// whoever ran the command, the machine half needs an administrator. Both
/// halves are idempotent, so running this twice is not an error.
#[cfg(windows)]
pub fn uninstall_with_elevation() -> std::process::ExitCode {
    let removed = rc_os::uninstall::remove_user_state();

    // Try the machine half in place first. If this process is already elevated —
    // or if there is nothing left to remove — no prompt is raised, and a
    // pointless one on every uninstall is how a product teaches users to click
    // "Yes" without reading.
    let mut removed = removed;
    removed.clsid = rc_vcam::uninstall_source().is_ok();
    removed.ring = rc_os::uninstall::remove_machine_files();
    if removed.is_complete() {
        return report_removal(&removed);
    }
    if !may_prompt() {
        eprintln!(
            "  {}",
            crate::i18n::t(
                "部分清理失败，且已在管理员权限下运行。",
                "Some parts could not be removed, and this was already running as administrator."
            )
        );
        return std::process::ExitCode::FAILURE;
    }

    match crate::elevate::run_elevated("--uninstall-vcam") {
        crate::elevate::Elevation::PromptAccepted => {
            println!(
                "  {}",
                crate::i18n::t("已清理干净。", "Removed cleanly.")
            );
            std::process::ExitCode::SUCCESS
        }
        _ => {
            eprintln!(
                "  {}",
                crate::i18n::t(
                    "部分清理失败。请以管理员身份再运行一次。",
                    "Some parts could not be removed. Run it once more as administrator."
                )
            );
            std::process::ExitCode::FAILURE
        }
    }
}

/// The machine-wide half on its own, with **no** prompt and **no** per-user work.
///
/// This is what the MSI's uninstall custom action calls. Two constraints shape
/// it, both learned the hard way:
///
///   * It runs as SYSTEM, where `%APPDATA%` resolves to the system profile's.
///     Calling the full `--uninstall-vcam` there would delete the wrong user's
///     data and leave the real user's behind — the uninstall would report
///     success while accomplishing nothing for the person who ran it.
///   * It must never try to elevate. A UAC prompt inside an uninstall would
///     either hang the install or fail silently, and either way the machine-wide
///     cleanup is the part that genuinely needs the rights we already have.
#[cfg(windows)]
fn uninstall_machine_only() -> std::process::ExitCode {
    let clsid = rc_vcam::uninstall_source().is_ok();
    let ring = rc_os::uninstall::remove_machine_files();
    if clsid && ring {
        println!(
            "  {}",
            crate::i18n::t("已清理干净。", "Removed cleanly.")
        );
        std::process::ExitCode::SUCCESS
    } else {
        eprintln!(
            "  {}",
            crate::i18n::t(
                "机器级清理失败（COM 注册或 ring 文件）。",
                "machine-wide cleanup failed (the COM registration or the ring file)."
            )
        );
        std::process::ExitCode::FAILURE
    }
}

#[cfg(windows)]
fn report_removal(removed: &rc_os::uninstall::Removed) -> std::process::ExitCode {
    if removed.is_complete() {
        println!(
            "  {}",
            crate::i18n::t("已清理干净。", "Removed cleanly.")
        );
        std::process::ExitCode::SUCCESS
    } else {
        eprintln!(
            "  {}",
            crate::i18n::t(
                "部分清理失败。",
                "Some parts could not be removed."
            )
        );
        std::process::ExitCode::FAILURE
    }
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
    // Already elevated and it still failed. Re-launching would raise a second
    // prompt, the copy would fail the same way, and the user would sit there
    // clicking "Yes" forever. This is the whole reason `is_elevated` exists.
    if crate::elevate::is_elevated() {
        return crate::elevate::Elevation::AlreadyElevated;
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
