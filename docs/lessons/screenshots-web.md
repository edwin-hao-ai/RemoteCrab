# 截图、宣传视频与站点

> 自动化"截图可用性"检查、模拟器 TCC 失效、截图必须分语言

Part of [`AGENTS.md`](../../AGENTS.md)。

76. **A readiness check that only tests "is it dark" cannot see a system
    alert.** `_shot_ok.py` accepted a frame if mean luminance < 100 and
    stddev > 5. An iOS permission alert is a *light grey card floating on the
    same near-black ground*, so it passes both tests. A whole batch of ten
    captures came back "ok" while every one was the local-network prompt. The
    fix measures the share of desaturated mid-grey and rejects > 6%: the bad
    batch reads 0.227, real UI 0.0035. **Generalisable: an automated "is this
    screenshot usable" check must test for the thing that actually makes it
    unusable, and you must look at the output yourself once** — the check
    passing was not evidence the images were good.

77. **A simulator TCC row you wrote is inert until `tccd` re-reads it
    (2026-09-27).** Three separate layers stack here:
    - `simctl privacy` cannot grant `kTCCServiceLocalNetwork` at all (it
      errors), so the seed must go straight into `TCC.db`.
    - `kTCCServiceCamera` and `kTCCServiceSpeechRecognition` are **dropped on
      every simulator reboot** (extends lesson 27), so `simctl privacy grant`
      is a silent no-op and the prompt covers the surface being captured.
    - Even with the rows present and `auth_value=2`, nothing happens:
      `tccd` caches every decision in memory, the simulator has no
      `killall` to bounce it, and `launchctl kickstart` wants
      `user/com.apple.tccd` but errors on that target from `simctl spawn`.
      **Only a boot-cycle makes `tccd` reload the file.** So
      `scripts/capture-feature-shots.sh` seeds five services and then
      shutdowns/boots the device before capturing. Without that step every
      capture is an alert, and lesson 76's check rejects all of them.

78. **The product UI is localised, so screenshots are per-locale — one set
    cannot serve both pages or both video cuts (2026-09-27).** An English
    landing page showing a Chinese screenshot reads as a different product,
    and the same applies to an English-narrated promo with Chinese screens
    inside it. `scripts/capture-feature-shots.sh <sim> <dd> <out> -en`
    takes the locale as a 4th arg and suffixes every filename; the site's
    feature pages pick `<slug>-en.jpg` on the English path and `<slug>.jpg`
    on the Chinese one, falling back across locales before the typographic
    panel. Corollary: the site had **no page at all** for the context-mode
    registry (`ContextProfiles.swift` — 18 suites, 49 bundle IDs), which is
    one of the stronger differentiators; it is now `/remotecrab/suites/`,
    with the suite titles taken from the app's own `IBLocale` strings so the
    site and the product say the same thing.
