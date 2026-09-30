//! When a downloaded update may install itself.
//!
//! The Mac half is [`UpdateInstallGate`]; this is the same policy with one more
//! condition, because Windows has one thing the Mac does not.
//!
//! An update that installs while the user is mid-session does not merely drop
//! the connection — it drops it *without explanation*, at the moment they were
//! relying on it. So the gate refuses while a session is live, while a
//! recording is running, and (this is the Windows-only one) **while input has
//! been injected in the last few seconds**, because on Windows the input path
//! is also what drives a mirrored window, and a restart in the middle of a drag
//! leaves a mouse button logically held down.
//!
//! Everything here is pure and tested on any host. The point is that the policy
//! is *the thing under test*, rather than something reconstructed from reading
//! a `select!` loop.

use std::time::Duration;

/// How long everything must be quiet before installing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Gate {
    /// Inactivity required before installing.
    pub dwell: Duration,
    /// How recently input counts as "still in use". Separate from `dwell`
    /// because a drag is continuous input and a gap between two events is not
    /// the same as an idle moment.
    pub input_grace: Duration,
}

impl Default for Gate {
    fn default() -> Self {
        Gate {
            dwell: Duration::from_secs(30),
            // Long enough to cover a pause between two events of the same
            // gesture, short enough that a genuinely idle machine installs
            // without the user wondering whether it is still working.
            input_grace: Duration::from_secs(3),
        }
    }
}

/// Everything the gate needs to know, as a snapshot.
///
/// Plain data with no clock in it, so a test states a time rather than sleeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Situation {
    /// An update has been downloaded and is waiting.
    pub pending_update: bool,
    /// A phone is connected and streaming.
    pub session_active: bool,
    /// A recording is being written.
    pub is_recording: bool,
    /// How long ago anything was injected, if ever.
    pub since_last_input: Option<Duration>,
}

impl Gate {
    /// May the update install now?
    pub fn should_install(&self, s: Situation) -> bool {
        if !s.pending_update || s.session_active || s.is_recording {
            return false;
        }
        // Input that has not had its grace period expire yet means a gesture
        // may still be in flight. `None` (never any input) is not "just now":
        // it means the app has been running quietly, which is the best case.
        if let Some(since) = s.since_last_input {
            if since < self.input_grace {
                return false;
            }
        }
        // The dwell timer is the caller's to keep; when asked, the caller passes
        // `since_last_input` for input and a separate flag for the rest. Here we
        // require the caller's own dwell check, so this returns true only when
        // the caller has *already* established the quiet period — hence no
        // `idle_since` parameter and the deliberate one-sided contract.
        true
    }

    /// The whole decision, including the dwell timer.
    ///
    /// `quiet_for` is how long the app has had no session, no recording and no
    /// input. Kept as a parameter rather than a clock so a test can state it.
    pub fn should_install_after(&self, s: Situation, quiet_for: Duration) -> bool {
        if let Some(since) = s.since_last_input {
            if since < self.input_grace {
                return false;
            }
        }
        self.should_install(s) && quiet_for >= self.dwell
    }
}

#[cfg(test)]
mod tests {
    use super::{Gate, Situation};
    use std::time::Duration;

    fn quiet() -> Situation {
        Situation {
            pending_update: true,
            session_active: false,
            is_recording: false,
            since_last_input: Some(Duration::from_secs(60)),
        }
    }

    /// The base case: everything is off, long enough, and it installs.
    #[test]
    fn an_idle_machine_installs() {
        let g = Gate::default();
        assert!(g.should_install_after(quiet(), Duration::from_secs(31)));
    }

    /// No update, nothing to install.
    #[test]
    fn nothing_happens_without_a_pending_update() {
        let g = Gate::default();
        let s = Situation {
            pending_update: false,
            ..quiet()
        };
        assert!(!g.should_install_after(s, Duration::from_secs(999)));
    }

    /// The three things that make a restart user-visible.
    #[test]
    fn a_live_session_or_a_recording_blocks_the_install() {
        let g = Gate::default();
        for s in [
            Situation {
                session_active: true,
                ..quiet()
            },
            Situation {
                is_recording: true,
                ..quiet()
            },
        ] {
            assert!(
                !g.should_install_after(s, Duration::from_secs(999)),
                "{s:?} should have blocked the install"
            );
        }
    }

    /// The Windows-only condition. A restart mid-drag leaves a button held.
    #[test]
    fn input_within_the_grace_period_blocks_the_install() {
        let g = Gate::default();
        for since in [
            Duration::from_millis(0),
            Duration::from_secs(1),
            Duration::from_secs(2),
        ] {
            let s = Situation {
                since_last_input: Some(since),
                ..quiet()
            };
            assert!(
                !g.should_install_after(s, Duration::from_secs(999)),
                "input {since:?} ago should block the install"
            );
        }
    }

    /// Long enough ago, and the gesture is over.
    #[test]
    fn input_older_than_the_grace_period_does_not_block() {
        let g = Gate::default();
        let s = Situation {
            since_last_input: Some(Duration::from_secs(4)),
            ..quiet()
        };
        assert!(g.should_install_after(s, Duration::from_secs(999)));
    }

    /// Never any input is the *best* case, not a suspicious one. Reading `None`
    /// as "just now" would mean a machine that has been idle since launch never
    /// updates.
    #[test]
    fn never_any_input_is_not_treated_as_just_now() {
        let g = Gate::default();
        let s = Situation {
            since_last_input: None,
            ..quiet()
        };
        assert!(g.should_install_after(s, Duration::from_secs(31)));
    }

    #[test]
    fn the_dwell_has_to_have_elapsed() {
        let g = Gate::default();
        assert!(!g.should_install_after(quiet(), Duration::from_secs(29)));
        assert!(g.should_install_after(quiet(), Duration::from_secs(30)));
    }

    /// Both timers, at once. This is the combination a single-condition gate
    /// gets wrong.
    #[test]
    fn both_conditions_must_hold_together() {
        let g = Gate::default();
        // Dwell satisfied but a gesture in flight.
        let in_flight = Situation {
            since_last_input: Some(Duration::from_millis(500)),
            ..quiet()
        };
        assert!(!g.should_install_after(in_flight, Duration::from_secs(600)));
        // Gesture long finished but not quiet long enough.
        let settled = Situation {
            since_last_input: Some(Duration::from_secs(120)),
            ..quiet()
        };
        assert!(!g.should_install_after(settled, Duration::from_secs(5)));
    }
}
