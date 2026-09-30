//! `remotecrab doctor` — why the iPhone is not connecting.
//!
//! "It doesn't connect" has at least five causes that look identical from the
//! outside: a VPN/proxy tunnel swallowing the route, a phone on another
//! network, an iOS app whose Local Network permission is off, an app that was
//! never started, and a firewall blocking discovery. Users were left to binary
//! search their own router. This ranks the causes from the evidence the
//! receiver can gather itself and prints what to do about each.
//!
//! The ranking is a pure function over [`Evidence`] so it can be tested without
//! a network; [`collect`] is the only part that touches the system.

use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use rc_net::route::{self, RouteVerdict};

/// How long to wait for a TCP connect. Long enough for a phone that is awake,
/// short enough that a dead address does not stall the report.
const PROBE_TIMEOUT: Duration = Duration::from_millis(1200);
/// How long to watch mDNS before concluding nothing is advertising.
const MDNS_WINDOW: Duration = Duration::from_secs(6);

/// What we managed to observe, gathered by [`collect`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Evidence {
    /// This machine's IPv4 addresses.
    pub local_addrs: Vec<String>,
    /// Where the OS would send traffic for the target (when we know it).
    pub route: RouteVerdict,
    /// Addresses mDNS reported, if any.
    pub mdns: Vec<String>,
    /// The address we probed, if the caller named one.
    pub target: Option<String>,
    /// Whether a TCP connect to `target:8765` succeeded.
    pub tcp_open: Option<bool>,
    /// True when a previous run reached the handshake and it did not finish.
    /// An open port on its own is good news, not a problem — it only becomes a
    /// finding when the handshake is what failed.
    pub handshake_failed: bool,
    /// True when the caller passed `--connect` and we skipped mDNS.
    pub mdns_skipped: bool,
}

/// One ranked finding, with the action that resolves it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    /// 1 = most likely.
    pub rank: u8,
    /// What is wrong.
    pub problem: String,
    /// What to do.
    pub fix: String,
}

/// Rank the evidence into findings, most likely first. Returns an empty vector
/// when everything checks out.
///
/// Ordering rationale: a hijacked route explains *every* symptom at once, so it
/// outranks everything; a reachable phone with a closed port is a phone-side
/// problem; no advertisements at all is a network-side problem.
pub fn rank(evidence: &Evidence) -> Vec<Finding> {
    let mut out = Vec::new();
    let mut rank = 1;

    if let RouteVerdict::Tunneled { source } = evidence.route {
        out.push(Finding {
            rank,
            problem: format!(
                "到 iPhone 的连接被 VPN/代理的虚拟网卡接管（源地址 {source}）——\
                 这会让同一 WiFi 下的手机完全连不上"
            ),
            fix: "关掉 Clash / Mihomo / sing-box 等的 TUN（虚拟网卡）模式，\
                  或在配置里把局域网直连：rules 加 IP-CIDR,192.168.0.0/16,DIRECT,no-resolve，\
                  tun 加 route-exclude-address: [192.168.0.0/16]"
                .to_string(),
        });
        rank += 1;
    }

    match evidence.tcp_open {
        Some(true) if evidence.handshake_failed => {
            out.push(Finding {
                rank,
                problem: "端口 8765 是通的，但握手没完成".to_string(),
                fix: "在 iPhone 上打开 RemoteCrab 并点「开始推流」，\
                      然后在弹出的卡片上允许这台电脑"
                    .to_string(),
            });
        }
        Some(false) if evidence.mdns.is_empty() => {
            out.push(Finding {
                rank,
                problem: "iPhone 所在网段没有任何设备在广播 RemoteCrab".to_string(),
                fix: "确认 iPhone 与本机连的是同一个 WiFi（不是访客网络——访客网默认与主网隔离）；\
                      在 iPhone 打开 设置 → 隐私与安全性 → 本地网络，允许 RemoteCrab；\
                      再回到 app 点「开始推流」"
                    .to_string(),
            });
        }
        Some(false) => {
            out.push(Finding {
                rank,
                problem: "能找到 iPhone，但 8765 端口没开".to_string(),
                fix: "iPhone 上 RemoteCrab 必须先点「开始推流」才会绑定端口；\
                      同时确认 设置 → 隐私与安全性 → 本地网络 已允许"
                    .to_string(),
            });
        }
        // An open port with a healthy handshake is the good case: nothing to
        // report, and saying otherwise would train users to ignore the tool.
        Some(true) => {}
        None => {}
    }

    if evidence.tcp_open.is_none() && evidence.mdns.is_empty() && !evidence.mdns_skipped {
        out.push(Finding {
            rank,
            problem: "mDNS 什么都没发现".to_string(),
            fix: "本机没有收到任何 _remotecrab._tcp 广播：\
                  iPhone 可能不在本机所在网段，或代理/防火墙拦了组播。\
                  可以先用 --connect <iPhone 的 IP> 绕过发现"
                .to_string(),
        });
    }

    out.sort_by_key(|f| f.rank);
    out
}

/// Gather the evidence. `target` is an optional `host:port` to probe directly;
/// when `None` this only browses mDNS.
///
/// Async because `rc_discovery::browse` must run inside a Tokio runtime.
pub async fn collect(target: Option<&str>) -> Evidence {
    let ours = route::local_ipv4();
    let local_addrs = ours.iter().map(|a| a.to_string()).collect::<Vec<_>>();

    if let Some(t) = target {
        if let Some(addr) = resolve(t) {
            // Route lookup and the connect probe are both cheap and
            // independent, so they can race.
            let (verdict, open) =
                tokio::join!(async { route::classify_route(addr, &ours) }, async {
                    tokio::task::spawn_blocking(move || tcp_open(addr))
                        .await
                        .unwrap_or(false)
                });
            return Evidence {
                local_addrs,
                route: verdict,
                mdns: Vec::new(),
                target: Some(t.to_string()),
                tcp_open: Some(open),
                handshake_failed: false,
                mdns_skipped: true,
            };
        }
    }

    let mdns = browse_once().await;
    Evidence {
        local_addrs,
        route: RouteVerdict::Unknown,
        mdns,
        target: None,
        tcp_open: None,
        handshake_failed: false,
        mdns_skipped: false,
    }
}

fn resolve(t: &str) -> Option<SocketAddr> {
    if let Ok(a) = t.parse::<SocketAddr>() {
        return Some(a);
    }
    // Bare IP without a port.
    let ip: std::net::IpAddr = t.parse().ok()?;
    Some(SocketAddr::new(ip, rc_net::DEFAULT_PORT))
}

fn tcp_open(addr: SocketAddr) -> bool {
    TcpStream::connect_timeout(&addr, PROBE_TIMEOUT).is_ok()
}

/// One mDNS sweep, bounded by [`MDNS_WINDOW`].
async fn browse_once() -> Vec<String> {
    let Ok(mut rx) = rc_discovery::browse(rc_net::SERVICE_TYPE) else {
        return Vec::new();
    };
    let mut found: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + MDNS_WINDOW;
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            break;
        }
        match tokio::time::timeout(left, rx.recv()).await {
            Ok(Some(rc_discovery::DiscoveryEvent::Found(phone))) => {
                let label = phone
                    .host
                    .clone()
                    .map(|h| format!("{h}:{}", phone.port))
                    .unwrap_or_else(|| format!("(resolving):{}", phone.port));
                let entry = format!("{} {label}", phone.name);
                if !found.contains(&entry) {
                    found.push(entry);
                }
            }
            Ok(Some(rc_discovery::DiscoveryEvent::Lost(_))) => {}
            Ok(None) | Err(_) => break,
        }
    }
    found
}

/// `run_doctor`: the `remotecrab doctor` entry point — print the evidence, then
/// the ranked causes with what to do about each. Exits 0 when nothing is wrong
/// and 1 when it found something to fix, so a support script can use it as a
/// gate.
pub async fn run_doctor(target: Option<&str>) -> std::process::ExitCode {
    println!(
        "RemoteCrab doctor {}\n",
        crate::i18n::t(
            "— 诊断为什么 iPhone 连不上",
            "— why the iPhone will not connect"
        )
    );
    let evidence = collect(target).await;

    println!("{}", crate::i18n::t("本机地址 / this PC:", "this PC:"));
    for a in &evidence.local_addrs {
        println!("  {a}");
    }
    match &evidence.route {
        rc_net::route::RouteVerdict::Direct => println!(
            "  {}",
            crate::i18n::t("路由正常：走真实网卡", "route: direct (real adapter)")
        ),
        other => println!("  route: {}", rc_net::route::describe(other)),
    }
    if let Some(t) = &evidence.target {
        let open = evidence.tcp_open.unwrap_or(false);
        let state = if open {
            crate::i18n::t("通", "open")
        } else {
            crate::i18n::t("不通", "closed")
        };
        println!(
            "  {} {t} {state}",
            crate::i18n::t("目标端口探测 / target probe:", "target probe:"),
        );
    }
    if evidence.mdns.is_empty() {
        println!(
            "  {}",
            crate::i18n::t("mDNS：没有发现任何 iPhone", "mDNS: no iPhone advertised")
        );
    } else {
        println!("  mDNS: {}", evidence.mdns.join(", "));
    }

    let findings = rank(&evidence);
    if findings.is_empty() {
        println!(
            "\n{}",
            crate::i18n::t(
                "没发现问题 —— 网络和手机都正常。",
                "Nothing wrong here — the network and the phone look fine."
            )
        );
        return std::process::ExitCode::SUCCESS;
    }
    println!();
    for f in &findings {
        println!("{}. {}", f.rank, f.problem);
        println!("   → {}\n", f.fix);
    }
    std::process::ExitCode::from(1)
}

// ---------------------------------------------------------------------------
// The "why isn't this connecting?" panel
// ---------------------------------------------------------------------------

const HEADING: &str = "RemoteCrab 连接状态 / connection";
const STATUS_LABEL: &str = "当前状态 / right now: ";
/// The tunnel finding, naming the offending address.
///
/// The address is the evidence: "something is tunnelling your traffic" is
/// arguable, "your traffic leaves as 198.18.0.1" is a fact the user can go and
/// confirm in their proxy client before changing anything.
fn tunnel_finding(source: &std::net::Ipv4Addr, zh: bool) -> String {
    let problem = t(
        zh,
        "最可能的原因：到手机的连接被 VPN / 代理的虚拟网卡接管了。",
        "Most likely cause: a VPN or proxy tunnel is taking over the route to your phone.",
    );
    let fix = t(
        zh,
        "要做什么：关掉 Clash / Mihomo / sing-box 等的「TUN（虚拟网卡）」模式；\
         或在它的配置里把局域网设为直连：\n\
         \x20 rules: IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\n\
         \x20 tun:\n\
         \x20   route-exclude-address: [192.168.0.0/16]",
        "What to do: turn off TUN mode in Clash / Mihomo / sing-box, or route the \
         local network directly:\n\
         \x20 rules: IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\n\
         \x20 tun:\n\
         \x20   route-exclude-address: [192.168.0.0/16]",
    );
    format!("{problem}\n{source}\n{fix}\n")
}
const LAST_RESORT: &str =
    "还是不行？在 iPhone 上打开 RemoteCrab、点「开始推流」，然后点本菜单里的「重新连接」。\n\
     Still stuck? Open RemoteCrab on the iPhone, press Start, then hit Reconnect in this menu.";

/// Pick the Chinese or English variant.
///
/// The language is a **parameter**, not a lookup into `i18n::is_chinese()`.
/// That call is a process-wide `OnceLock` seeded from the OS, so a test that
/// used it would only ever assert whichever language the machine happens to
/// run — which is why the Chinese wording of the tray and the panel had no
/// real coverage at all. Passing it in keeps these functions pure and lets
/// both languages be tested anywhere.
fn t(zh_first: bool, zh: &str, en: &str) -> String {
    (if zh_first { zh } else { en }).to_string()
}

/// The full explanation, for a dialog.
///
/// Deliberately **no probing and no input fields**. The user did not open this
/// to debug a socket; they opened it because something is not working, and the
/// only useful answer is a reason and a next step. An address box would be
/// shipping a debug affordance as the product's escape hatch (AGENTS.md rule 1)
/// — and the one case a developer-only control seems to be needed (a TUN-mode
/// VPN swallowing the LAN) has a copy-pasteable configuration fix instead,
/// which is something a user can actually act on.
///
/// Pure, so the whole wording is unit-tested and the tray only renders it.
pub fn panel(h: &rc_net::Health, verdict: &RouteVerdict, zh: bool) -> String {
    let mut out = String::new();
    out.push_str(HEADING);
    out.push_str("\n\n");
    out.push_str(STATUS_LABEL);
    out.push_str(&state_line(h, zh));
    out.push('\n');

    // A hijacked route explains every symptom at once, so it leads.
    if let RouteVerdict::Tunneled { source } = verdict {
        out.push_str(&format!("\n{}\n", tunnel_finding(source, zh)));
    }

    if !matches!(h.state, rc_net::State::Streaming { .. }) {
        for (problem, fix) in hints(h, zh) {
            out.push_str(&format!("\n- {problem}\n  {fix}\n"));
        }
    }

    out.push_str(&format!("\n{LAST_RESORT}\n"));
    out
}

/// The one-line reason, for the menu row itself.
///
/// The menu must answer "why not?" without a click — a status line that owes
/// the user a reason has to carry it (AGENTS.md rule 1) — but a Win32 menu
/// cannot wrap, so this is deliberately short and [`panel`] holds the detail.
pub fn panel_summary(h: &rc_net::Health, verdict: &RouteVerdict, zh: bool) -> String {
    use rc_net::State;
    if let RouteVerdict::Tunneled { source } = verdict {
        return t(
            zh,
            &format!("被 VPN/代理接管（{source}）"),
            &format!("a VPN/proxy tunnel took the route ({source})"),
        );
    }
    match &h.state {
        State::Streaming { .. } => t(zh, "已连接", "connected"),
        State::Busy { owner } => t(
            zh,
            &format!("iPhone 正被「{owner}」使用"),
            &format!("the iPhone is in use by {owner}"),
        ),
        State::AwaitingApproval { .. } => t(
            zh,
            "等你在 iPhone 上点「允许」",
            "waiting for you to tap Allow",
        ),
        State::Error(_) => t(zh, "连接失败", "the connection failed"),
        State::Connecting { .. } | State::Handshaking { .. } => t(zh, "正在连接", "connecting"),
        State::Searching if !h.discovered.is_empty() => t(
            zh,
            "找到了 iPhone，但连不上",
            "found the iPhone, but cannot connect",
        ),
        State::Searching if h.fallback_misses > 0 => t(
            zh,
            "没找到 iPhone（已扫过局域网）",
            "no iPhone found (local network already scanned)",
        ),
        State::Searching => t(zh, "没找到 iPhone", "no iPhone found"),
    }
}

/// A one-line, human description of the state. Never a raw enum name and never
/// a raw OS error string (AGENTS.md lesson 13).
fn state_line(h: &rc_net::Health, zh: bool) -> String {
    use rc_net::State;
    match &h.state {
        State::Streaming { name, latency_ms } if *latency_ms > 0 => {
            format!("{name} - {latency_ms} ms")
        }
        State::Streaming { name, .. } => name.clone(),
        State::Busy { owner } => t(
            zh,
            &format!("iPhone 正被「{owner}」使用"),
            &format!("The iPhone is in use by {owner}"),
        ),
        State::AwaitingApproval { name } => t(
            zh,
            &format!("等待你在 iPhone 上允许「{name}」"),
            &format!("Waiting for you to allow {name} on the iPhone"),
        ),
        State::Connecting { name } | State::Handshaking { name } => t(
            zh,
            &format!("正在连接 {name}"),
            &format!("Connecting to {name}"),
        ),
        State::Error(e) => t(
            zh,
            &format!("连接失败：{e}"),
            &format!("Connection failed: {e}"),
        ),
        State::Searching if h.discovered.is_empty() => {
            t(zh, "正在寻找 iPhone", "Looking for your iPhone")
        }
        State::Searching => t(zh, "已断开", "Disconnected"),
    }
}

/// The concrete next steps implied by what we have and have not seen.
fn hints(h: &rc_net::Health, zh: bool) -> Vec<(String, String)> {
    use rc_net::State;
    let mut out = Vec::new();

    match &h.state {
        State::Busy { owner } => {
            out.push((
                t(zh, &format!("iPhone 正被「{owner}」使用，所以这台电脑在等。"),
                    &format!("Another computer ({owner}) is using the iPhone, so this one is waiting."),
                ),
                t(zh, "iPhone 会自动把会话交出来；你也可以在 iPhone 上「选择电脑」立刻切过来。",
                    "The iPhone hands the session over on its own, or pick this computer there to switch immediately.",
                ),
            ));
            return out;
        }
        State::Error(_) | State::AwaitingApproval { .. } => {
            out.push((
                t(zh, "iPhone 还没有接受这台电脑。",
                    "The iPhone has not accepted this computer yet.",
                ),
                t(zh, "在 iPhone 上点「允许」。第一次连接、以及 iPhone 重装之后需要点一次。",
                    "Tap Allow on the iPhone. Needed once per iPhone, and again after the app is reinstalled.",
                ),
            ));
            return out;
        }
        _ => {}
    }

    if !h.discovered.is_empty() {
        out.push((
            t(zh, &format!("局域网里找到了 {} 台 iPhone，但没能建立连接。", h.discovered.len()),
                &format!(
                    "Found {} iPhone(s) on this network but could not connect.",
                    h.discovered.len()
                ),
            ),
            t(zh, "在 iPhone 上打开 RemoteCrab 并点「开始推流」—— 端口只有在开始推流之后才会打开。",
                "Open RemoteCrab on the iPhone and press Start — the port only opens once streaming starts.",
            ),
        ));
    } else {
        let scan_note = if h.fallback_misses > 0 {
            t(
                zh,
                &format!(
                    "（已经直接扫过你的局域网 {} 次，也没找到。）",
                    h.fallback_misses
                ),
                &format!(
                    " (We also scanned your local network {} times, and found nothing.)",
                    h.fallback_misses
                ),
            )
        } else {
            String::new()
        };
        out.push((
            format!(
                "{}{scan_note}",
                t(zh, "这台电脑没有发现任何 iPhone。", "No iPhone was discovered on this network.")
            ),
            t(zh, "确认 iPhone 和这台电脑连的是同一个 WiFi（访客网络通常与主网隔离）；\
                 并在 iPhone 的「设置 → 隐私与安全性 → 本地网络」里允许 RemoteCrab。",
                "Check that the iPhone and this computer are on the same WiFi (guest networks are usually \
                 isolated), and allow RemoteCrab under Settings → Privacy → Local Network on the iPhone.",
            ),
        ));
    }

    if let Some(ep) = &h.last_endpoint {
        out.push((
            format!(
                "{}{ep}",
                t(zh, "上次成功连接：", "Last successful connection: ")
            ),
            t(
                zh,
                "iPhone 换地址（换 WiFi）之后会自动用新地址重试。",
                "If the iPhone's address changed, the new one is retried automatically.",
            ),
        ));
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Evidence {
        Evidence {
            local_addrs: vec!["192.168.31.159".into()],
            route: RouteVerdict::Direct,
            mdns: vec![],
            target: None,
            tcp_open: None,
            handshake_failed: false,
            mdns_skipped: false,
        }
    }
    #[test]
    fn a_clean_network_produces_no_findings() {
        let mut e = base();
        e.mdns = vec!["iPhone 192.168.31.5:8765".into()];
        e.target = Some("192.168.31.5:8765".into());
        e.tcp_open = Some(true);
        e.mdns_skipped = true;
        assert!(rank(&e).is_empty(), "{:?}", rank(&e));
    }

    /// An open port is good news on its own — the phone is right there.
    #[test]
    fn an_open_port_alone_is_not_a_finding() {
        let mut e = base();
        e.tcp_open = Some(true);
        assert!(rank(&e).is_empty(), "{:?}", rank(&e));
    }

    /// …and only becomes a finding once we know the handshake is what failed.
    #[test]
    fn an_open_port_with_a_failed_handshake_points_at_approval() {
        let mut e = base();
        e.tcp_open = Some(true);
        e.handshake_failed = true;
        let findings = rank(&e);
        assert_eq!(findings.len(), 1, "{findings:?}");
        assert!(findings[0].fix.contains("允许"), "{findings:?}");
    }

    #[test]
    fn a_tunnel_outranks_everything_and_comes_first() {
        let mut e = base();
        e.route = RouteVerdict::Tunneled {
            source: "198.18.0.1".parse().unwrap(),
        };
        e.tcp_open = Some(false);
        let findings = rank(&e);
        assert!(findings.len() >= 2, "{findings:?}");
        assert!(findings[0].problem.contains("VPN"), "{:?}", findings[0]);
        assert_eq!(findings[0].rank, 1);
        assert!(
            findings[0].fix.contains("DIRECT"),
            "the fix must be copy-pasteable"
        );
        // Ranks are dense and ascending.
        for w in findings.windows(2) {
            assert_eq!(w[1].rank, w[0].rank + 1, "{findings:?}");
        }
    }

    #[test]
    fn no_advertisements_points_at_the_phone_side_settings() {
        let mut e = base();
        e.tcp_open = Some(false);
        let findings = rank(&e);
        let joined = findings.iter().map(|f| f.fix.as_str()).collect::<String>();
        assert!(joined.contains("本地网络"), "{findings:?}");
        assert!(joined.contains("访客网络"), "{findings:?}");
    }

    #[test]
    fn found_but_closed_port_is_a_different_answer() {
        let mut e = base();
        e.mdns = vec!["iPhone 192.168.31.5:8765".into()];
        e.tcp_open = Some(false);
        let findings = rank(&e);
        assert!(findings[0].problem.contains("8765"), "{findings:?}");
        assert!(findings[0].fix.contains("开始推流"), "{findings:?}");
        assert!(
            !findings[0].fix.contains("访客网络"),
            "one cause, one fix: {findings:?}"
        );
    }

    #[test]
    fn open_port_means_the_phone_is_waiting_for_approval() {
        let mut e = base();
        e.tcp_open = Some(true);
        e.handshake_failed = true;
        let findings = rank(&e);
        assert!(findings[0].fix.contains("允许"), "{findings:?}");
    }

    #[test]
    fn silence_with_no_target_reports_only_the_discovery_problem() {
        let findings = rank(&base());
        assert_eq!(findings.len(), 1, "{findings:?}");
        assert!(findings[0].problem.contains("mDNS"), "{findings:?}");
    }

    // -----------------------------------------------------------------------
    // The panel
    //
    // These exist because the wording is the product here. A tray row that
    // says "LOOKING" and nothing else is what turned "it sometimes connects"
    // into an afternoon of binary search (AGENTS.md rule 1).
    // -----------------------------------------------------------------------

    fn health(state: rc_net::State) -> rc_net::Health {
        rc_net::Health {
            state,
            ..Default::default()
        }
    }

    #[test]
    fn a_working_session_says_so_and_offers_nothing_to_fix() {
        for zh in [true, false] {
            let h = health(rc_net::State::Streaming {
                name: "Fake iPhone".into(),
                latency_ms: 12,
            });
            let text = panel(&h, &RouteVerdict::Direct, zh);
            assert!(text.contains("Fake iPhone"), "zh={zh} {text}");
            // No troubleshooting for a session that works — telling a happy
            // user to check their firewall trains them to ignore the panel.
            assert!(!text.contains("TUN"), "zh={zh} {text}");
            assert!(!text.contains("Local Network"), "zh={zh} {text}");
            assert!(!text.contains("本地网络"), "zh={zh} {text}");
        }
    }

    /// A menu row cannot wrap, so the summary must be one short line that
    /// still names the reason.
    #[test]
    fn the_summary_always_names_a_reason_and_stays_on_one_line() {
        for zh in [true, false] {
            let cases = [
                health(rc_net::State::Busy {
                    owner: "MacBook".into(),
                }),
                health(rc_net::State::Error("boom".into())),
                health(rc_net::State::Searching),
                health(rc_net::State::AwaitingApproval { name: "PC".into() }),
            ];
            for h in cases {
                let s = panel_summary(&h, &RouteVerdict::Direct, zh);
                assert!(!s.trim().is_empty(), "zh={zh} empty for {h:?}");
                assert!(!s.contains('\n'), "zh={zh} must be one line: {s:?}");
            }
            // Busy must name the holder — that is the whole point of the row.
            let busy = panel_summary(
                &health(rc_net::State::Busy {
                    owner: "MacBook".into(),
                }),
                &RouteVerdict::Direct,
                zh,
            );
            assert!(busy.contains("MacBook"), "zh={zh} {busy}");
        }
    }

    #[test]
    fn a_tunnel_outranks_everything_and_is_actionable() {
        for zh in [true, false] {
            let h = health(rc_net::State::Searching);
            let v = RouteVerdict::Tunneled {
                source: "198.18.0.1".parse().unwrap(),
            };
            let text = panel(&h, &v, zh);
            assert!(
                text.contains("198.18.0.1"),
                "zh={zh} names the address: {text}"
            );
            assert!(text.contains("TUN"), "zh={zh} names the switch: {text}");
            // A user has to be able to act on this without a manual.
            assert!(text.contains("route-exclude-address"), "zh={zh} {text}");
            assert!(panel_summary(&h, &v, zh).contains("198.18.0.1"), "zh={zh}");
        }
    }

    /// The distinction the user actually needs: "the PC cannot see me" is a
    /// completely different problem from "the PC found me and was refused".
    #[test]
    fn found_but_unreachable_differs_from_never_seen() {
        for zh in [true, false] {
            let mut seen = health(rc_net::State::Searching);
            seen.discovered = vec!["Fake iPhone".into()];
            let found = panel(&seen, &RouteVerdict::Direct, zh);
            // Phone-side cause: it has to be running and streaming.
            let phone_side = ["开始推流", "press Start"];
            assert!(
                phone_side.iter().any(|k| found.contains(k)),
                "zh={zh} {found}"
            );
            // …and must NOT tell them to go looking at their WiFi.
            let network_side = ["确认 iPhone", "same WiFi"];
            assert!(
                !network_side.iter().any(|k| found.contains(k)),
                "zh={zh} found-but-closed must not blame the network: {found}"
            );

            let unseen = panel(&health(rc_net::State::Searching), &RouteVerdict::Direct, zh);
            let net = ["确认 iPhone", "same WiFi"];
            assert!(net.iter().any(|k| unseen.contains(k)), "zh={zh} {unseen}");
            let perm = ["本地网络", "Local Network"];
            assert!(perm.iter().any(|k| unseen.contains(k)), "zh={zh} {unseen}");
        }
    }

    #[test]
    fn the_panel_reports_that_it_actually_scanned() {
        for zh in [true, false] {
            let mut h = health(rc_net::State::Searching);
            h.fallback_misses = 4;
            let text = panel(&h, &RouteVerdict::Direct, zh);
            // The count is what stops the user from assuming nothing was tried.
            assert!(text.contains('4'), "zh={zh} {text}");
        }
    }

    #[test]
    fn the_panel_always_ends_with_an_action() {
        for zh in [true, false] {
            for s in [
                rc_net::State::Searching,
                rc_net::State::Error("x".into()),
                rc_net::State::Busy { owner: "m".into() },
                rc_net::State::AwaitingApproval { name: "n".into() },
            ] {
                let text = panel(&health(s), &RouteVerdict::Direct, zh);
                let action = ["重新连接", "Reconnect"];
                assert!(action.iter().any(|k| text.contains(k)), "zh={zh} {text}");
            }
        }
    }

    #[test]
    fn the_last_working_endpoint_is_reported() {
        for zh in [true, false] {
            let mut h = health(rc_net::State::Searching);
            h.last_endpoint = Some("192.168.1.5:8765".into());
            let text = panel(&h, &RouteVerdict::Direct, zh);
            assert!(text.contains("192.168.1.5:8765"), "zh={zh} {text}");
        }
    }

    #[test]
    fn resolve_accepts_both_forms() {
        assert_eq!(resolve("192.168.31.5:8765").unwrap().port(), 8765);
        assert_eq!(resolve("192.168.31.5").unwrap().port(), 8765);
        assert!(resolve("not-an-address").is_none());
    }
}
