//! Deciding what the first-run check should say, and what it should offer.
//!
//! Pure, and tested on any host — which matters more here than usual, because
//! the thing it decides is whether a user believes the product works. The
//! Windows equivalent of "grant Accessibility on macOS" is not a settings
//! toggle: it is the process **integrity level**, and there is nothing to
//! grant. A program at `medium` cannot inject input into a `high` or `system`
//! window, and `SendInput` fails silently when it tries.
//!
//! So the states are the states of the *world*, not of a permission, and each
//! one has a different remedy — or none, which is the hardest to say out loud.

/// Whether the virtual camera is registered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Camera {
    /// Registered, so the receiver appears in every app's camera list.
    Ready,
    /// Not registered. Recoverable in one click — it raises a UAC prompt (see
    /// `rc-app`'s install row).
    Missing,
}

/// The process integrity level, which on Windows plays the role macOS's
/// Accessibility grant plays: it decides whether `SendInput` can reach a given
/// window. There is nothing to *grant* — it is a property of how the program was
/// launched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Integrity {
    /// Elevated: can inject into elevated windows too.
    High,
    /// The default. Drives ordinary windows, not elevated ones. **Not a fault**,
    /// and the wizard must not present it as one.
    Medium,
    /// Under a hardened policy or some sandboxes. Input injection is then
    /// mostly impossible, and no amount of clicking fixes it.
    Low,
}

impl Integrity {
    /// Whether input — which *is* the product — can be expected to work.
    pub fn can_inject(self) -> bool {
        !matches!(self, Integrity::Low)
    }
}

/// The whole first-run picture, as the wizard renders it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FirstRun {
    pub camera: Camera,
    pub integrity: Integrity,
    /// Start-at-login is on. Read from the registry, so a stale Run value shows
    /// up here rather than as a lie in the menu.
    pub autostart: bool,
    /// The notification relay — off unless the user asked.
    pub notify_relay: bool,
}

impl FirstRun {
    /// The steps to show, in order, each with whether it is satisfied.
    ///
    /// A wizard that shows a list of things is a list of things to read. Each
    /// step therefore carries its own remedy, or an explicit "nothing to do",
    /// because AGENTS.md is explicit that a line saying what is happening must
    /// also say what to do.
    pub fn steps(&self) -> Vec<Step> {
        vec![
            Step {
                blocking: true,
                title: (
                    "触控板 / 键盘能控制这台电脑".to_string(),
                    "Trackpad and keyboard can control this PC".to_string(),
                ),
                done: self.integrity.can_inject(),
                // No remedy for this one, because there is nothing to grant:
                // it is a property of how the program was launched. Saying so
                // is more useful than "permission denied".
                //
                // And no remedy for a *medium* process either, even though one
                // exists now. The thing that would fix it is the logon task, which
                // is the same setting the row below turns on — so the instruction
                // belongs on that row, where the user can act on it and where it is
                // already written, rather than repeated here on a step that is
                // satisfied.
                remedy: match self.integrity {
                    Integrity::Low => Some((
                        "系统以低权限模式启动，无法向多数窗口发送输入。请用管理员身份运行一次。"
                            .to_string(),
                        "started at low integrity, so input cannot reach most windows. Run it once \
                         as administrator."
                            .to_string(),
                    )),
                    _ => None,
                },
            },
            Step {
                blocking: true,
                title: (
                    "虚拟摄像头（让电脑把它当成摄像头）".to_string(),
                    "Virtual camera (so apps see it as a camera)".to_string(),
                ),
                done: self.camera == Camera::Ready,
                remedy: match self.camera {
                    Camera::Missing => Some((
                        "在托盘菜单里点「安装虚拟摄像头」，允许管理员提示即可。".to_string(),
                        "pick \"Install virtual camera\" in the tray menu and allow the admin prompt"
                            .to_string(),
                    )),
                    _ => None,
                },
            },
            Step {
                blocking: true,
                title: (
                    "开机自动启动".to_string(),
                    "Start at login".to_string(),
                ),
                done: self.autostart,
                remedy: (!self.autostart).then(|| {
                    (
                        "在设置里打开「开机自动启动」。它会让接收端以管理员权限启动，\
                         因此也能控制管理员权限的窗口。"
                            .to_string(),
                        "turn on \"Start at login\" in Settings. It starts the receiver elevated, \
                         so it can drive windows running as administrator too."
                            .to_string(),
                    )
                }),
            },
            Step {
                blocking: false,
                title: (
                    "通知中继（可选，默认关）".to_string(),
                    "Notification relay (optional, off by default)".to_string(),
                ),
                // Optional, so it is never "unfinished" and never blocks the
                // wizard. It is still *shown*, because a feature the user does
                // not know about is a feature they will not turn on — and while
                // it is off the remedy is a suggestion rather than a fix, which
                // is why this one is the single place `done` and `remedy` can
                // both be set.
                done: self.notify_relay,
                remedy: (!self.notify_relay).then(|| {
                    (
                        "在托盘菜单里开启「通知中继」，Windows 会问一次通知权限。".to_string(),
                        "turn on \"Notification relay\" in the tray menu; Windows will ask once for \
                         notification access"
                            .to_string(),
                    )
                }),
            },
        ]
    }

    /// Whether the wizard has anything **blocking** left to say.
    ///
    /// A wizard that reappears with nothing to do is a nag; it is shown once, on
    /// first run, and only if something blocking is genuinely missing. An
    /// optional step with a remedy is a suggestion, not a reason to interrupt.
    pub fn has_anything_to_say(&self) -> bool {
        self.steps().iter().any(|s| s.blocking && !s.done)
    }
}

/// One row of the wizard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub title: (String, String),
    pub done: bool,
    /// Whether this step being unfinished should re-show the wizard.
    ///
    /// Separate from `done` because the relay is the case that needs the two to
    /// differ: it is "not yet on", so it shows a remedy, but it is *optional*,
    /// so it must never make the wizard come back. Folding this into `done`
    /// would mean either nagging forever or hiding a feature nobody will find.
    pub blocking: bool,
    /// `None` when there is nothing to do. Deliberately *not* an empty string:
    /// a step with a blank remedy is how a wizard grows a column of blank
    /// lines that the user learns to skip.
    pub remedy: Option<(String, String)>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_good() -> FirstRun {
        FirstRun {
            camera: Camera::Ready,
            integrity: Integrity::Medium,
            autostart: true,
            notify_relay: false,
        }
    }

    /// A missing virtual camera is one *feature* being absent. The product is
    /// still usable, and telling the user otherwise would be a lie that makes
    /// them look for a bigger problem.
    #[test]
    fn a_missing_camera_does_not_make_the_product_unusable() {
        let fr = FirstRun {
            camera: Camera::Missing,
            ..all_good()
        };
        assert_eq!(fr.camera, Camera::Missing);
        assert!(fr.integrity.can_inject());
    }

    /// Low integrity is different: input *is* the product, and it will not
    /// work.
    #[test]
    fn low_integrity_is_the_one_state_that_breaks_the_product() {
        assert!(!Integrity::Low.can_inject());
        assert!(Integrity::Medium.can_inject());
        assert!(Integrity::High.can_inject());
    }

    /// The rule from AGENTS.md, as a test: every unfinished step owes the user
    /// an action.
    #[test]
    fn an_unfinished_step_always_says_what_to_do() {
        let fr = FirstRun {
            camera: Camera::Missing,
            integrity: Integrity::Low,
            autostart: false,
            notify_relay: false,
        };
        for step in fr.steps() {
            if !step.done {
                let (zh, en) = step
                    .remedy
                    .clone()
                    .expect("an unfinished step needs a remedy");
                assert!(!zh.trim().is_empty(), "{zh:?}");
                assert!(!en.trim().is_empty(), "{en:?}");
            }
        }
    }

    /// …and a finished step shows no remedy, with exactly one exception: the
    /// optional relay row, which is "finished" (it does not block anything) and
    /// still suggests turning it on. That asymmetry is deliberate and is the
    /// only one, so it is named here rather than left to be rediscovered.
    #[test]
    fn only_the_optional_row_may_be_done_and_still_suggest_something() {
        for step in all_good().steps() {
            let is_optional_relay = step.title.1.contains("optional");
            if step.done && !is_optional_relay {
                assert!(
                    step.remedy.is_none(),
                    "a satisfied step should not be telling the user to do something: {:?}",
                    step.title
                );
            }
        }
    }

    /// The relay is optional, so it can never be the reason the wizard shows.
    #[test]
    fn the_optional_relay_never_blocks_completion() {
        let mut fr = all_good();
        assert!(!fr.has_anything_to_say());
        fr.notify_relay = true;
        assert!(!fr.has_anything_to_say());
    }

    /// A wizard that reappears with nothing to say is a nag.
    #[test]
    fn the_wizard_stays_quiet_when_there_is_nothing_to_do() {
        assert!(!all_good().has_anything_to_say());
        assert!(FirstRun {
            camera: Camera::Missing,
            ..all_good()
        }
        .has_anything_to_say());
    }

    /// Every step's title must be nameable in both languages, including the ones
    /// that are already satisfied — the wizard lists them all.
    #[test]
    fn every_step_is_labelled_in_both_languages() {
        for step in all_good().steps() {
            assert!(!step.title.0.trim().is_empty());
            assert!(!step.title.1.trim().is_empty());
        }
    }
}
