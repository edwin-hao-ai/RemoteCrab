//! Tiny UI localization for the console + notification-area tray.
//!
//! The Mac/iOS apps localize through Apple String Catalogs; the Windows
//! command-line/tray surface has no such machinery, so this picks Chinese
//! when the Windows UI language is Chinese and English otherwise — the same
//! two languages the Apple side ships, chosen from the user's system
//! setting rather than a flag.

use std::sync::OnceLock;

/// True when the user's Windows UI language is Chinese (any region).
pub fn is_chinese() -> bool {
    static ZH: OnceLock<bool> = OnceLock::new();
    *ZH.get_or_init(|| {
        #[cfg(windows)]
        {
            // LANGID: low 10 bits are the primary language id; 0x04 = zh.
            // (Non-Windows dev builds just use English.)
            unsafe {
                (windows::Win32::Globalization::GetUserDefaultUILanguage() & 0x3FF) == 0x04
            }
        }
        #[cfg(not(windows))]
        {
            false
        }
    })
}

/// Pick the Chinese or English string for the current UI language.
#[inline]
pub fn t<'a>(zh: &'a str, en: &'a str) -> &'a str {
    if is_chinese() { zh } else { en }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_one_of_the_two_languages() {
        let s = t("中文", "English");
        assert!(s == "中文" || s == "English");
    }
}
