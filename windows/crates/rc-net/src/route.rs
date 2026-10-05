//! Which local address the OS would use to reach a given destination.
//!
//! A VPN/proxy client in TUN mode (Clash / Mihomo / sing-box and most
//! "加速器") takes over the default route, so a connection to a phone sitting
//! on the same WiFi gets pulled into the tunnel and dropped. From the app that
//! is indistinguishable from "the phone is switched off" — the receiver just
//! says "not connected" forever, and the user has no idea which switch to flip.
//! Naming the adapter is the whole point of this module.
//!
//! The probe is the standard UDP trick: bind an unconnected socket, `connect`
//! it (which sends nothing but forces a route lookup), then read
//! `local_addr()`. A pure function decides what that source address means, so
//! the judgement is unit-testable on every platform.

use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};

/// What the route lookup says about a destination.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteVerdict {
    /// Traffic leaves through one of this machine's own addresses — the
    /// ordinary same-network case.
    Direct,
    /// Traffic leaves through an address that is not ours: a tunnel adapter
    /// (TUN/TAP/WAN Miniport) claimed the destination. Carries the offending
    /// source address so the message can name it.
    Tunneled { source: Ipv4Addr },
    /// No route at all, or the lookup failed.
    Unknown,
}

/// The address the OS would send this machine from, or `None` if the lookup
/// failed (no route, offline, IPv6-only destination).
pub fn source_for(target: SocketAddr) -> Option<Ipv4Addr> {
    let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect(target).ok()?;
    match sock.local_addr().ok()?.ip() {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(_) => None,
    }
}

/// Decide what a source address means.
///
/// `ours` is this machine's own addresses (loopback counts: a loopback source
/// can only happen for a loopback destination). Anything else is somebody
/// else's address space — in practice a tunnel's fake-IP pool.
pub fn classify_source(source: Option<Ipv4Addr>, ours: &[Ipv4Addr]) -> RouteVerdict {
    match source {
        None => RouteVerdict::Unknown,
        Some(src) if ours.contains(&src) => RouteVerdict::Direct,
        Some(source) => RouteVerdict::Tunneled { source },
    }
}

/// Classify the route to `target`, taking this machine's addresses from
/// `ours` (injectable so tests do not depend on the host's real adapters).
pub fn classify_route(target: SocketAddr, ours: &[Ipv4Addr]) -> RouteVerdict {
    classify_source(source_for(target), ours)
}

/// This machine's IPv4 addresses, excluding link-local (`169.254.0.0/16`).
///
/// Link-local addresses come from DHCP-less adapters (Hyper-V, VPN, WSL) and
/// are not a sign of tunnelling, but they are also not a usable identity for a
/// peer on the LAN, so they are left out.
///
/// **This is the routing table's opinion, not the adapter table's.** Under a TUN
/// proxy the address it returns for a public destination is the tunnel's own —
/// which is why [`lan_source_for`] exists and why a dial must not use this.
pub fn local_ipv4() -> Vec<Ipv4Addr> {
    // No `getifaddrs` without a crate: one datagram to a public address is
    // enough to make the OS pick the interface it would use by default, and
    // loopback covers the local case.
    let mut out = vec![Ipv4Addr::LOCALHOST];
    for probe in ["1.1.1.1:80", "8.8.8.8:53"] {
        if let Ok(addr) = probe.parse::<SocketAddr>() {
            if let Some(v4) = source_for(addr) {
                if !v4.is_link_local() && !out.contains(&v4) {
                    out.push(v4);
                }
            }
        }
    }
    out
}


// The adapter table lives in `rc-discovery`, not here: the presence
// advertisement needs the same answer ("which address can a peer reach me on"),
// and it cannot depend on this crate. Re-exported so the dial path and its tests
// keep their names.
pub use rc_discovery::{adapters, lan_source_for, pick_lan, prefix_mask, Adapter};
/// One-line, user-facing description of a verdict. Empty for `Direct` — the
/// caller only prints something when there is something to say.
pub fn describe(verdict: &RouteVerdict) -> String {
    match verdict {
        RouteVerdict::Direct => String::new(),
        RouteVerdict::Tunneled { source } => format!(
            "到目标的连接会被 VPN/代理的虚拟网卡（{source}）接管。\n\
             怎么办（二选一）：\n\
             \x20 1. 关掉该代理软件的 TUN / 虚拟网卡模式；\n\
             \x20 2. 或者给它加一条局域网直连规则，用本机所在的网段：\n\
             \x20    Clash/Mihomo：rules 里加 `IP-CIDR,<本机网段>,DIRECT,no-resolve`\n\
             \x20    （例如 IP-CIDR,192.168.31.0/24,DIRECT），并把该网段加进\n\
             \x20    `dns.fake-ip-filter`，否则光有 rules 也不够。\n\
             上面「网卡」一节里没有标注隧道的那个地址，就是本机网段。"
        ),
        RouteVerdict::Unknown => "没有到该目标的路由（离线或网络不可达）。".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINE: [Ipv4Addr; 2] = [Ipv4Addr::LOCALHOST, Ipv4Addr::new(192, 168, 31, 159)];

    #[test]
    fn our_own_address_is_direct() {
        let v = classify_source(Some(MINE[1]), &MINE);
        assert_eq!(v, RouteVerdict::Direct);
        assert!(describe(&v).is_empty(), "the happy path says nothing");
    }

    #[test]
    fn a_foreign_address_is_a_tunnel() {
        let fake_ip = Ipv4Addr::new(198, 18, 0, 1);
        let v = classify_source(Some(fake_ip), &MINE);
        assert_eq!(v, RouteVerdict::Tunneled { source: fake_ip });
        let text = describe(&v);
        assert!(text.contains("198.18.0.1"), "names the address: {text}");
        assert!(text.contains("TUN"), "names the fix: {text}");
    }

    #[test]
    fn no_route_is_unknown() {
        assert_eq!(classify_source(None, &MINE), RouteVerdict::Unknown);
    }

    /// A real route lookup, against a socket on this machine: the source the
    /// OS picks must be one of ours, i.e. never a tunnel.
    #[test]
    fn loopback_probe_reports_our_own_address() {
        let listener = UdpSocket::bind("127.0.0.1:0").unwrap();
        let target = listener.local_addr().unwrap();
        let source = source_for(target).expect("loopback route must resolve");
        assert_eq!(source, Ipv4Addr::LOCALHOST);
        assert_eq!(classify_source(Some(source), &MINE), RouteVerdict::Direct);
    }

    #[test]
    fn local_ipv4_always_contains_loopback_and_never_link_local() {
        let addrs = local_ipv4();
        assert!(addrs.contains(&Ipv4Addr::LOCALHOST));
        assert!(addrs.iter().all(|a| !a.is_link_local()), "{addrs:?}");
    }

    fn adapter(index: u32, addr: &str, prefix_len: u8, tunnel: bool) -> Adapter {
        Adapter {
            index,
            addr: addr.parse().expect("test address"),
            prefix_len,
            tunnel,
        }
    }

    /// The exact shape of the bug this exists for: the TUN adapter claims the
    /// phone's subnet (or all of it), and a naive "which adapter covers the
    /// phone" picks the tunnel and the dial disappears into it.
    #[test]
    fn a_tunnel_covering_the_phone_is_never_the_way_out() {
        let adapters = [
            adapter(1, "198.18.0.1", 16, true),
            adapter(2, "192.168.31.103", 24, false),
        ];
        assert_eq!(
            pick_lan(&adapters, "192.168.31.148".parse().unwrap()),
            Some("192.168.31.103".parse().unwrap()),
            "the physical adapter shares the phone's subnet; the tunnel does not"
        );
    }

    /// A tunnel on `0.0.0.0/0` covers everything, so if it were allowed to
    /// qualify there would be no safe answer at all. `None` is the safe answer:
    /// the caller dials unbound, exactly as it did before this existed.
    #[test]
    fn a_tunnel_covers_everything_and_still_loses() {
        let adapters = [adapter(1, "198.18.0.1", 0, true)];
        assert_eq!(pick_lan(&adapters, "192.168.31.148".parse().unwrap()), None);
    }

    /// Loopback matches almost any prefix, including /0, and can never reach a
    /// phone.
    #[test]
    fn loopback_is_never_the_way_out() {
        let adapters = [adapter(1, "127.0.0.1", 8, false)];
        assert_eq!(pick_lan(&adapters, "127.0.0.5".parse().unwrap()), None);
    }

    /// Two real adapters on overlapping subnets: the more specific one is the
    /// right source, not whichever the OS enumerated first.
    #[test]
    fn the_longest_prefix_wins() {
        let adapters = [
            adapter(1, "10.0.0.5", 8, false),
            adapter(2, "10.1.2.5", 24, false),
        ];
        assert_eq!(
            pick_lan(&adapters, "10.1.2.9".parse().unwrap()),
            Some("10.1.2.5".parse().unwrap())
        );
    }

    /// An address on no adapter's subnet means we do not know how to reach it,
    /// and guessing would be worse than not binding.
    #[test]
    fn a_phone_on_no_local_subnet_has_no_source() {
        let adapters = [adapter(1, "192.168.31.103", 24, false)];
        assert_eq!(pick_lan(&adapters, "10.0.0.7".parse().unwrap()), None);
    }

    /// `OnLinkPrefixLength` comes from the OS, and a bogus value must not become
    /// a shift overflow — which panics in debug and is worse in release.
    #[test]
    fn prefix_lengths_out_of_range_are_clamped() {
        assert_eq!(prefix_mask(0), 0);
        assert_eq!(prefix_mask(24), 0xFFFF_FF00);
        assert_eq!(prefix_mask(32), u32::MAX);
        assert_eq!(prefix_mask(255), u32::MAX);
    }
}
