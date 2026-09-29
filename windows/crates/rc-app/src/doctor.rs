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
                  tun 加 route-exclude-address: [192.168.0.0/16]".to_string(),
        });
        rank += 1;
    }

    match evidence.tcp_open {
        Some(true) if evidence.handshake_failed => {
            out.push(Finding {
                rank,
                problem: "端口 8765 是通的，但握手没完成".to_string(),
                fix: "在 iPhone 上打开 RemoteCrab 并点「开始推流」，\
                      然后在弹出的卡片上允许这台电脑".to_string(),
            });
        }
        Some(false) if evidence.mdns.is_empty() => {
            out.push(Finding {
                rank,
                problem: "iPhone 所在网段没有任何设备在广播 RemoteCrab".to_string(),
                fix: "确认 iPhone 与本机连的是同一个 WiFi（不是访客网络——访客网默认与主网隔离）；\
                      在 iPhone 打开 设置 → 隐私与安全性 → 本地网络，允许 RemoteCrab；\
                      再回到 app 点「开始推流」".to_string(),
            });
        }
        Some(false) => {
            out.push(Finding {
                rank,
                problem: "能找到 iPhone，但 8765 端口没开".to_string(),
                fix: "iPhone 上 RemoteCrab 必须先点「开始推流」才会绑定端口；\
                      同时确认 设置 → 隐私与安全性 → 本地网络 已允许".to_string(),
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
                  可以先用 --connect <iPhone 的 IP> 绕过发现".to_string(),
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
            let (verdict, open) = tokio::join!(
                async { route::classify_route(addr, &ours) },
                async {
                    tokio::task::spawn_blocking(move || tcp_open(addr))
                        .await
                        .unwrap_or(false)
                }
            );
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
        crate::i18n::t("— 诊断为什么 iPhone 连不上", "— why the iPhone will not connect")
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
        e.route = RouteVerdict::Tunneled { source: "198.18.0.1".parse().unwrap() };
        e.tcp_open = Some(false);
        let findings = rank(&e);
        assert!(findings.len() >= 2, "{findings:?}");
        assert!(findings[0].problem.contains("VPN"), "{:?}", findings[0]);
        assert_eq!(findings[0].rank, 1);
        assert!(findings[0].fix.contains("DIRECT"), "the fix must be copy-pasteable");
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

    #[test]
    fn resolve_accepts_both_forms() {
        assert_eq!(resolve("192.168.31.5:8765").unwrap().port(), 8765);
        assert_eq!(resolve("192.168.31.5").unwrap().port(), 8765);
        assert!(resolve("not-an-address").is_none());
    }
}
