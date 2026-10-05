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

/// One IPv4 address on one interface, as the OS's *adapter table* describes it
/// — as opposed to `local_ipv4`, which reports what the routing table would
/// pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Adapter {
    /// `IfIndex`. Also what `IP_UNICAST_IF` wants, if the `bind` approach is not
    /// enough on some network.
    pub index: u32,
    pub addr: Ipv4Addr,
    pub prefix_len: u8,
    /// The OS classifies this interface as a tunnel (TUN/TAP/WAN Miniport) or
    /// loopback. Both are excluded from dialling: the first is the problem, the
    /// second cannot reach a phone.
    pub tunnel: bool,
}

impl Adapter {
    /// Whether `target` is on this adapter's own subnet.
    pub fn covers(&self, target: Ipv4Addr) -> bool {
        let mask = prefix_mask(self.prefix_len);
        u32::from(self.addr) & mask == u32::from(target) & mask
    }
}

/// A prefix length as a network-order mask. Out-of-range values are clamped
/// rather than trusted: a bad `OnLinkPrefixLength` from the OS would otherwise
/// shift-overflow, which panics in debug and is undefined-shaped in release.
fn prefix_mask(prefix_len: u8) -> u32 {
    match prefix_len {
        0 => 0,
        32.. => u32::MAX,
        n => u32::MAX << (32 - n),
    }
}

/// Which local address a dial to `target` should leave from.
///
/// Only an address that is **on the target's own subnet** and **not a tunnel**
/// will do, and that combination is the whole fix: under a TUN proxy the routing
/// table sends a same-WiFi destination into the tunnel, so the only way to reach
/// the phone is to ask a physical interface to carry it — and the interface that
/// shares the phone's subnet is the one that can.
///
/// `None` when nothing qualifies, which leaves the caller on the ordinary route.
/// An unbound dial is exactly what happened before this existed, so the fallback
/// is not a degradation.
pub fn lan_source_for(target: Ipv4Addr) -> Option<Ipv4Addr> {
    pick_lan(&adapters(), target)
}

/// The selection itself, over a list the caller supplies.
///
/// Split out so the decision is a unit test: `adapters()` reaches the OS, and a
/// test that needs a TUN adapter and a WiFi adapter on the same subnet should
/// not need either to exist on the machine running it.
pub fn pick_lan(adapters: &[Adapter], target: Ipv4Addr) -> Option<Ipv4Addr> {
    adapters
        .iter()
        // Loopback first: it covers plenty of subnets by prefix (`0.0.0.0/0`
        // among them) and can never reach a phone.
        .filter(|a| !a.tunnel && a.addr != Ipv4Addr::LOCALHOST && !a.addr.is_link_local())
        .filter(|a| a.covers(target))
        // Longest prefix wins, so a machine with both a /16 and a /24 on the
        // same link picks the more specific one rather than whichever the OS
        // happened to enumerate first.
        .max_by_key(|a| a.prefix_len)
        .map(|a| a.addr)
}

#[cfg(windows)]
pub fn adapters() -> Vec<Adapter> {
    use windows::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_INCLUDE_PREFIX, GAA_FLAG_SKIP_ANYCAST,
        GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows::Win32::Networking::WinSock::{AF_INET, AF_UNSPEC, SOCKADDR_IN};

    /// `IF_TYPE_SOFTWARE_LOOPBACK` / `IF_TYPE_TUNNEL`, from `ipifcons.h`. Spelled
    /// as numbers because the `windows` crate exposes them under a feature this
    /// crate does not otherwise need.
    const IF_TYPE_SOFTWARE_LOOPBACK: u32 = 24;
    const IF_TYPE_TUNNEL: u32 = 131;

    // `GAA_FLAG_INCLUDE_PREFIX` is not optional: without it Windows leaves
    // `OnLinkPrefixLength` as zero, every adapter then claims to cover nothing,
    // and the whole feature silently does nothing.
    let flags = GAA_FLAG_SKIP_ANYCAST
        | GAA_FLAG_SKIP_MULTICAST
        | GAA_FLAG_SKIP_DNS_SERVER
        | GAA_FLAG_INCLUDE_PREFIX;

    // Two calls by design: the first sizes the buffer and is expected to fail
    // with ERROR_BUFFER_OVERFLOW.
    let mut size: u32 = 0;
    unsafe {
        let _ = GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, None, &mut size);
    }
    if size == 0 {
        return Vec::new();
    }

    let mut buffer = vec![0u8; size as usize];
    let first = buffer.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
    let rc = unsafe { GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, Some(first), &mut size) };
    if rc != 0 {
        return Vec::new();
    }

    let mut out = Vec::new();
    let mut node = first;
    while !node.is_null() {
        // SAFETY: `node` walks the linked list the API filled in `buffer`, and
        // every node is null-terminated.
        let adapter = unsafe { &*node };
        let description = wide_to_string(adapter.Description);
        let tunnel = adapter.IfType == IF_TYPE_TUNNEL
            || adapter.IfType == IF_TYPE_SOFTWARE_LOOPBACK
            || named_like_a_tunnel(&description);

        let mut unicast = adapter.FirstUnicastAddress;
        while !unicast.is_null() {
            // SAFETY: as above — this list is inside the same buffer.
            let entry = unsafe { &*unicast };
            let sockaddr = entry.Address.lpSockaddr;
            if !sockaddr.is_null() && unsafe { (*sockaddr).sa_family } == AF_INET {
                // SAFETY: an `AF_INET` sockaddr is a `SOCKADDR_IN`; the family
                // check just above is what makes that true.
                let v4 = unsafe { &*(sockaddr as *const SOCKADDR_IN) };
                // `S_addr` is the address in network order. Going through its
                // *memory* bytes is endianness-proof in a way that reading the
                // `u32` and swapping is not.
                let bytes = unsafe { v4.sin_addr.S_un.S_addr.to_ne_bytes() };
                out.push(Adapter {
                    // `IfIndex` lives in the first union member, alongside
                    // `Length` — the Windows header groups them that way.
                    index: unsafe { adapter.Anonymous1.Anonymous.IfIndex },
                    addr: Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]),
                    prefix_len: entry.OnLinkPrefixLength,
                    tunnel,
                });
            }
            unicast = entry.Next;
        }
        node = adapter.Next;
    }
    out
}

/// Off Windows there is no adapter table to walk without pulling in `getifaddrs`
/// or a crate. `None` means the caller dials unbound — the same behaviour as
/// before this existed, and these builds are the parity harness rather than a
/// product.
#[cfg(not(windows))]
pub fn adapters() -> Vec<Adapter> {
    Vec::new()
}

/// Name fragments that are proxies or tunnels in practice.
///
/// A heuristic, and the *second* signal rather than the first: `IfType` is the
/// authoritative answer. But a WinTun-based proxy — Mihomo, sing-box, a
/// WireGuard client in its wintun mode — reports itself as an ordinary Ethernet
/// adapter, so for the class of software this module exists to work around the
/// name is all that is left to go on.
///
/// Over-matching is the safe direction here: worst case a real adapter is
/// excluded as a dial source, and the caller then dials unbound, which is what
/// every dial did before this existed.
pub fn named_like_a_tunnel(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "tun", "tap", "wintun", "wireguard", "openvpn", "clash", "mihomo", "sing-box", "singbox",
        "v2ray", "shadowsocks", "vpn",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

/// A `PWSTR` from the adapter table as a `String`. The API guarantees
/// null-termination; a null pointer is an adapter with no description.
#[cfg(windows)]
fn wide_to_string(p: windows::core::PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let mut len = 0usize;
    // SAFETY: the API's own strings are NUL-terminated and live in the buffer we
    // allocated, which outlives this call.
    unsafe {
        while *p.0.add(len) != 0 {
            len += 1;
            // A runaway pointer would otherwise walk off the end of the process.
            if len > 1024 {
                break;
            }
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(p.0, len))
    }
}

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
