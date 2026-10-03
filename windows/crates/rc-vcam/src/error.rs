//! Why a virtual-camera operation failed, in a form the UI can *act* on.
//!
//! This exists because the previous signature was `Result<(), String>`, and the
//! one case the product must handle specially — "this needs administrator
//! rights" — was only distinguishable by matching English words inside that
//! string. That is unfixable in practice: change the wording and the product
//! silently stops offering to elevate, which looks exactly like "the virtual
//! camera does not work on this machine".
//!
//! The rule this encodes (AGENTS.md): a failure the user can do something about
//! has to be *identifiable*, so the UI can offer that one action instead of
//! printing a sentence and giving up.

use std::fmt;

/// What went wrong, and — more importantly — what the user can do about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VcamError {
    /// Writing `HKLM` needs an elevated process. Recoverable, and the only
    /// recovery is a UAC prompt, so the caller should offer exactly that.
    NeedsElevation(&'static str),
    /// The COM source DLL is not next to the executable. A packaging fault, not
    /// something a user can click their way out of.
    SourceMissing(String),
    /// The DLL path is registered, but to somewhere else. Recoverable by
    /// re-registering (which needs elevation).
    Stale,
    /// Anything else, with the underlying message for the log.
    Other(String),
}

impl VcamError {
    /// Whether offering a UAC prompt could plausibly fix this.
    ///
    /// The UI uses this to decide between "click here and approve" and
    /// "here is what is wrong, this is not your fault". Guessing wrong in the
    /// first direction means a pointless UAC prompt; wrong in the second means
    /// the user is told to contact support for a missing file.
    pub fn is_fixable_by_elevating(&self) -> bool {
        matches!(self, VcamError::NeedsElevation(_) | VcamError::Stale)
    }
}

impl fmt::Display for VcamError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VcamError::NeedsElevation(what) => write!(
                f,
                "{what} needs administrator rights — approve the Windows prompt and it is done"
            ),
            VcamError::SourceMissing(path) => write!(
                f,
                "the camera source DLL is missing at {path} — this is a packaging problem, \
                 not something you can fix"
            ),
            VcamError::Stale => write!(
                f,
                "the camera is registered to a different file — reinstalling it needs \
                 administrator rights"
            ),
            VcamError::Other(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for VcamError {}

#[cfg(test)]
mod tests {
    use super::VcamError;

    #[test]
    fn only_the_recoverable_cases_offer_a_uac_prompt() {
        assert!(VcamError::NeedsElevation("registering the camera").is_fixable_by_elevating());
        assert!(VcamError::Stale.is_fixable_by_elevating());
        // A missing DLL is a packaging fault. Prompts cannot conjure a file, and
        // a UAC prompt the user cannot act on is worse than an honest message.
        assert!(!VcamError::SourceMissing("C:/x.dll".into()).is_fixable_by_elevating());
        assert!(!VcamError::Other("access denied".into()).is_fixable_by_elevating());
    }

    /// The wording is user-facing, so it must not read like an error enum.
    #[test]
    fn the_message_says_what_to_do() {
        let m = VcamError::NeedsElevation("registering the camera").to_string();
        assert!(m.contains("administrator"), "{m}");
        assert!(!m.contains("VcamError"), "{m}");
    }

    /// `Stale` used to be unreachable: `install_source` compared the registered
    /// DLL against its own and, on a mismatch, fell through to a bare
    /// `ACCESS_DENIED`. So the one error that could actually explain the
    /// situation never reached a user. Now that `win.rs` returns it, hold the
    /// message to the standard the other arms meet — it must not read as "you
    /// are not an administrator", which is what the user concludes from the
    /// generic message and is usually wrong.
    #[test]
    fn a_stale_registration_does_not_read_as_a_permissions_problem() {
        let m = VcamError::Stale.to_string();
        assert!(m.contains("different file"), "{m}");
        assert!(
            !m.contains("not an administrator") && !m.contains("permission"),
            "{m}"
        );
    }
}
