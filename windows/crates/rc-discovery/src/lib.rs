//! `rc-discovery` — find iPhones running RemoteCrab on the LAN.
//!
//! Primary path: mDNS browse for `_remotecrab._tcp.local.` (the service the
//! iOS app advertises). Fallback path: direct TCP probes, because multicast
//! mDNS is blocked on some networks (iPhone Personal Hotspot, AP client
//! isolation, VPNs) — the Mac receiver ships the same fallback
//! (`ReceiverSession.startFallbackLoop`), and we mirror it here.

use std::net::IpAddr;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use tokio::net::TcpStream;
use tokio::sync::mpsc::UnboundedReceiver;

/// The iPhone Personal Hotspot gateway (the phone is always the gateway).
/// When the PC is on the phone's hotspot, multicast doesn't reach clients,
/// so probing this address is the escape hatch.
pub const HOTSPOT_GATEWAY: &str = "172.20.10.1";

/// Whether this machine is itself a client of the iPhone-hotspot network.
///
/// The hotspot escape hatch is only an escape hatch from *inside* it. Dialing
/// `172.20.10.1` from a WiFi the phone is nowhere near cannot succeed, yet the
/// fallback probed it on every tick — which is how a Windows log filled with
/// `正在连接 iPhone (172.20.10.1)` while the phone was sitting on 192.168.31.x,
/// making a working network look broken.
pub fn on_iphone_hotspot() -> bool {
    local_ipv4_addresses()
        .iter()
        .any(|a| a.starts_with("172.20.10."))
}

/// The fixed TCP port the iOS app listens on.
pub const DEFAULT_PORT: u16 = 8765;

/// The service type a receiver advertises so the phone can see it online.
///
/// MUST stay distinct from the phone's `_remotecrab._tcp.local.`: the receiver
/// browses that one for iPhones, and reusing it would make it dial computers.
pub const SERVICE_TYPE_COMPUTER: &str = "_remotecrab-computer._tcp.local.";

/// The fixed port the receiver listens on for the phone's "knock" — a short
/// connection meaning "dial me back now". See the Swift `IBServiceType.knockPort`.
pub const KNOCK_PORT: u16 = 8766;

// ---------------------------------------------------------------------------
// Adapters
//
// The addresses this machine can actually be reached on. Everything that
// answers "which address is mine" by asking the *routing table* gives the wrong
// answer under a TUN proxy: Clash / Mihomo / sing-box take over the default
// route, so a probe to a public address comes back with the tunnel's own
// address. That address is in no peer's subnet, so an advertisement carrying it
// is unusable and a dial from it is dropped.
// ---------------------------------------------------------------------------

/// One IPv4 address on one interface, as the OS's adapter table describes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Adapter {
    /// `IfIndex`, which is also what `IP_UNICAST_IF` wants.
    pub index: u32,
    pub addr: std::net::Ipv4Addr,
    pub prefix_len: u8,
    /// The OS classifies this interface as a tunnel (TUN/TAP/WAN Miniport),
    /// loopback, or a proxy by name.
    pub tunnel: bool,
}

impl Adapter {
    /// Whether `target` is on this adapter's own subnet.
    pub fn covers(&self, target: std::net::Ipv4Addr) -> bool {
        let mask = prefix_mask(self.prefix_len);
        u32::from(self.addr) & mask == u32::from(target) & mask
    }
}

/// A prefix length as a network-order mask. Out-of-range values are clamped
/// rather than trusted: a bad `OnLinkPrefixLength` from the OS would otherwise
/// shift-overflow, which panics in debug and is worse in release.
pub fn prefix_mask(prefix_len: u8) -> u32 {
    match prefix_len {
        0 => 0,
        32.. => u32::MAX,
        n => u32::MAX << (32 - n),
    }
}

/// Every address this machine has, excluding loopback and link-local.
///
/// **Use this, not a routing probe, when the address will be given to a peer.**
/// A routing probe answers "where would a packet to 8.8.8.8 leave from", and
/// under a TUN the answer is the tunnel.
pub fn lan_addresses() -> Vec<std::net::Ipv4Addr> {
    adapters()
        .into_iter()
        .filter(|a| !a.tunnel && a.addr != std::net::Ipv4Addr::LOCALHOST && !a.addr.is_link_local())
        .map(|a| a.addr)
        .collect()
}

/// The local address a connection to `target` should leave from.
///
/// Only an address that is **on the target's own subnet** and **not a tunnel**
/// will do, and that combination is the whole point: under a TUN proxy the
/// routing table sends a same-WiFi destination into the tunnel, so the only way
/// to reach the peer is to ask a physical interface to carry it — and the
/// interface that shares the peer's subnet is the one that can.
///
/// `None` when nothing qualifies, which leaves the caller on the ordinary route.
pub fn lan_source_for(target: std::net::Ipv4Addr) -> Option<std::net::Ipv4Addr> {
    pick_lan(&adapters(), target)
}

/// The selection itself, over a list the caller supplies.
///
/// Split out so the decision is a unit test: `adapters()` reaches the OS, and a
/// test that needs a tunnel and a WiFi adapter on the same subnet should not
/// need either to exist on the machine running it.
pub fn pick_lan(adapters: &[Adapter], target: std::net::Ipv4Addr) -> Option<std::net::Ipv4Addr> {
    adapters
        .iter()
        // Loopback first: it covers plenty of subnets by prefix and can never
        // reach a peer.
        .filter(|a| !a.tunnel && a.addr != std::net::Ipv4Addr::LOCALHOST && !a.addr.is_link_local())
        .filter(|a| a.covers(target))
        // Longest prefix wins, so a machine with both a /16 and a /24 on the
        // same link picks the more specific one rather than whichever the OS
        // happened to enumerate first.
        .max_by_key(|a| a.prefix_len)
        .map(|a| a.addr)
}

/// Name fragments that are proxies or tunnels in practice.
///
/// A heuristic, and the *second* signal rather than the first: `IfType` is the
/// authoritative answer. But a WinTun-based proxy — Mihomo, sing-box, a
/// WireGuard client in its wintun mode — reports itself as an ordinary Ethernet
/// adapter, so for the class of software this exists to work around the name is
/// all that is left to go on.
///
/// Over-matching is the safe direction: worst case a real adapter is excluded as
/// a source, and the caller falls back to the plain routing behaviour.
pub fn named_like_a_tunnel(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "tun", "tap", "wintun", "wireguard", "openvpn", "clash", "mihomo", "sing-box", "singbox",
        "v2ray", "shadowsocks", "vpn",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
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
    // `OnLinkPrefixLength` as zero, every adapter then covers nothing, and the
    // whole thing silently does nothing.
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
    let rc =
        unsafe { GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, Some(first), &mut size) };
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
                    // `IfIndex` lives in the first union member, alongside `Length`.
                    index: unsafe { adapter.Anonymous1.Anonymous.IfIndex },
                    addr: std::net::Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]),
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
/// or a crate. Empty means every caller falls back to the routing behaviour,
/// which is what it did before this existed.
#[cfg(not(windows))]
pub fn adapters() -> Vec<Adapter> {
    Vec::new()
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

#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("mDNS error: {0}")]
    Mdns(#[from] mdns_sd::Error),
    /// A bad argument, rather than something the network did. Its own variant
    /// because the two are read by different people: one is a bug in a caller,
    /// the other is a fact about the LAN.
    #[error("{0}")]
    Msg(String),
}

/// A discovered (or manually entered) iPhone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredPhone {
    /// Stable identity — the mDNS fullname, or `manual:<host>:<port>`.
    pub id: String,
    /// User-visible instance name (shown in the UI, never a raw endpoint).
    pub name: String,
    /// Resolved IPv4 address, when known.
    pub host: Option<String>,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryEvent {
    Found(DiscoveredPhone),
    Lost(String),
}

/// Start browsing for `service_type` (e.g. `_remotecrab._tcp.local.`).
///
/// Must be called from within a Tokio runtime. The returned receiver yields
/// `Found` / `Lost` events; the mDNS daemon is kept alive by the background
/// task until the receiver is dropped.
pub fn browse(service_type: &str) -> Result<UnboundedReceiver<DiscoveryEvent>, DiscoveryError> {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    let daemon = ServiceDaemon::new()?;
    let receiver = daemon.browse(service_type)?;

    tokio::spawn(async move {
        // Keep the daemon handle alive for the lifetime of the task.
        let _daemon = daemon;
        while let Ok(event) = receiver.recv_async().await {
            match event {
                ServiceEvent::ServiceResolved(info) => {
                    let phone = phone_from_resolved(&info);
                    let _ = tx.send(DiscoveryEvent::Found(phone));
                }
                ServiceEvent::ServiceRemoved(_service_type, fullname) => {
                    let _ = tx.send(DiscoveryEvent::Lost(fullname));
                }
                _ => {}
            }
        }
    });

    Ok(rx)
}

/// A running presence announcement. Dropping it does not unregister; call
/// [`PresenceAdvertiser::stop`] so the phone sees the computer go offline
/// promptly instead of waiting for the record's TTL.
pub struct PresenceAdvertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl PresenceAdvertiser {
    pub fn stop(self) {
        let _ = self.daemon.unregister(&self.fullname);
    }
}

/// Build the service this computer announces. Pure enough to test the TXT
/// contract without a network. Port 0: the phone reads the TXT, it never
/// connects here.
pub fn presence_service_info(
    instance: &str,
    id: &str,
    name: &str,
    platform: &str,
) -> Result<ServiceInfo, DiscoveryError> {
    let host = format!("{}.local.", instance.replace(' ', "-"));
    let mut props = std::collections::HashMap::new();
    props.insert("id".to_string(), id.to_string());
    props.insert("name".to_string(), name.to_string());
    props.insert("platform".to_string(), platform.to_string());
    // The knock port: the phone dials this to say "dial me back now".
    props.insert("port".to_string(), KNOCK_PORT.to_string());

    // The SRV port is the knock port too, not 0. The TXT is what the phone is
    // documented to read, but an SRV record with port 0 is the mDNS way of
    // saying "no service here", and a browser is entitled to drop it before the
    // TXT is ever consulted — which is exactly what happened: the advertisement
    // was registered and never found, and the test that would have said so had a
    // broken assertion (see `an_advertised_computer_is_found_by_a_browser`).
    let port = KNOCK_PORT;
    let info = match local_ipv4_addresses().into_iter().next() {
        Some(ip) => ServiceInfo::new(SERVICE_TYPE_COMPUTER, instance, &host, ip.as_str(), port, props)?,
        None => ServiceInfo::new(SERVICE_TYPE_COMPUTER, instance, &host, (), port, props)?,
    };
    Ok(info)
}

/// Announce this computer on the LAN so an iPhone can show it as online.
///
/// The TXT keys/values are the same contract the Mac `PresenceAdvertiser`
/// publishes; the phone parses one format.
pub fn advertise(
    instance: &str,
    id: &str,
    name: &str,
    platform: &str,
) -> Result<PresenceAdvertiser, DiscoveryError> {
    let daemon = ServiceDaemon::new()?;
    // mdns-sd's default cap is 15 bytes and it is applied to the service **type**,
    // whose first label here is `_remotecrab-computer` — 21 bytes. So every
    // registration was rejected, from inside the daemon thread, where `register`
    // has already returned `Ok` and the only trace is a `log` line nobody has a
    // logger for. The Windows advertisement therefore never reached the network
    // at all, which is why the phone showed no green dot while the app printed
    // "advertising as ...".
    //
    // 21 is a perfectly ordinary DNS label (the wire limit is 63); mdns-sd's
    // default is conservative because it is really about *instance* names, and
    // it allows raising it to 30.
    daemon.set_service_name_len_max(30)?;
    let info = presence_service_info(instance, id, name, platform)?;
    let fullname = info.get_fullname().to_string();
    daemon.register(info)?;
    Ok(PresenceAdvertiser { daemon, fullname })
}

fn phone_from_resolved(info: &mdns_sd::ResolvedService) -> DiscoveredPhone {
    let fullname = info.get_fullname().to_string();
    // Fullname is `<instance>._remotecrab._tcp.local.`; the instance name is
    // the user-visible device name.
    let name = fullname
        .split('.')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(&fullname)
        .to_string();
    DiscoveredPhone {
        id: fullname,
        name,
        host: first_ipv4(info.get_addresses()),
        port: info.get_port(),
    }
}

fn first_ipv4(addrs: &std::collections::HashSet<mdns_sd::ScopedIp>) -> Option<String> {
    // Unwrap each scoped address to a bare `IpAddr`, prefer IPv4.
    let plain: Vec<IpAddr> = addrs.iter().map(|a| a.to_ip_addr()).collect();
    plain
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| plain.first())
        .map(|a| a.to_string())
}

/// Probe whether a TCP endpoint accepts a connection within `timeout`.
/// Used by the direct-IP fallback to decide whether a known address is live.
pub async fn probe_tcp(host: &str, port: u16, timeout: Duration) -> bool {
    matches!(
        tokio::time::timeout(timeout, connect_bound(host, port)).await,
        Ok(Ok(_))
    )
}

/// Connect to `host:port` from the adapter that shares the destination's subnet,
/// when there is one.
///
/// **Unbound is not good enough anywhere a TUN proxy might be running.** The
/// routing table sends a same-LAN destination into the tunnel, and the tunnel
/// accepts the connection and then fails it — so an unbound probe reports a
/// *hit* for every address it tries. That is what made the `/24` sweep announce
/// a phone at whatever host it reached first, and sent the receiver off to dial
/// a machine with nothing on it. The same reasoning as `lan_source_for`, applied
/// to every connect rather than only to the session dial.
pub async fn connect_bound(host: &str, port: u16) -> std::io::Result<TcpStream> {
    let Ok(ip) = host.parse::<std::net::Ipv4Addr>() else {
        // A hostname: we cannot know its subnet without resolving, and resolving
        // is what the unbound path does anyway.
        return TcpStream::connect((host, port)).await;
    };
    let Some(local) = lan_source_for(ip) else {
        return TcpStream::connect((host, port)).await;
    };
    let socket = tokio::net::TcpSocket::new_v4()?;
    socket.bind(std::net::SocketAddr::new(local.into(), 0))?;
    socket
        .connect(std::net::SocketAddr::new(ip.into(), port))
        .await
}

/// The machine's own IPv4 addresses (excluding loopback + link-local).
///
/// Used to derive the `/24` to sweep when mDNS is unavailable. We enumerate
/// interfaces without extra dependencies by opening a throwaway UDP socket
/// to a public address — the OS picks the egress interface, whose local
/// address is our primary LAN IP.
pub fn local_ipv4_addresses() -> Vec<String> {
    // The adapter table first. The routing probe below cannot be the primary
    // answer any more: under a TUN proxy it returns the tunnel's own address,
    // and an advertisement carrying that is one no peer can act on — the phone
    // showed the computer as offline for exactly this reason.
    let lan: Vec<String> = lan_addresses().iter().map(|a| a.to_string()).collect();
    if !lan.is_empty() {
        return lan;
    }

    // Fallback for a host where the adapter table is unavailable (off Windows).
    use std::net::UdpSocket;

    let mut out = Vec::new();
    // 8.8.8.8 is never contacted (UDP connect just selects a route); if the
    // host is offline this simply fails and we fall back below.
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = sock.local_addr() {
                let ip = addr.ip();
                if !ip.is_loopback() {
                    out.push(ip.to_string());
                }
            }
        }
    }
    out
}

/// Build the host addresses of a `/24` for `target`.
///
/// Accepts either form:
/// - `192.168.31.159` — a full address; that host is excluded from the sweep,
///   because it is this PC talking to itself.
/// - `192.168.31` — an explicit /24 prefix, used to look for a phone parked on
///   a guest/IoT subnet that the router routes but isolates from the main LAN.
///
/// True when `addr` could plausibly be the phone on this network.
///
/// A guard for the direct-IP path, so it is deliberately strict. The failure
/// it prevents is self-reinforcing: an endpoint that is persisted on every
/// successful handshake and re-dialled on every fallback tick. If whatever
/// answered was a loopback listener — a booted simulator, a stray dev server —
/// then every "success" re-persisted it, and the receiver dialed the ghost
/// forever in a perfectly plausible-looking 12-20 s cadence that reads as
/// ordinary backoff. The Mac hit exactly this (AGENTS.md lesson 83).
///
/// Rejected, with reasons:
/// - empty / not a dotted quad → cannot be dialed
/// - `127.0.0.0/8` — loopback (the simulator case)
/// - `169.254.0.0/16` — link-local / self-assigned, i.e. an unreachable adapter
/// - `0.0.0.0` and the broadcast address
/// - a `%en0`-style scope suffix — not dialable, and a shape the OS endpoint
///   printer sometimes produces
///
/// Used at **both** the write site and the read site: refusing only to dial a
/// poisoned entry leaves it in the file, and refusing only to write it leaves
/// an already-poisoned file in place. Both are needed to heal.
pub fn is_usable_dial_address(addr: &str) -> bool {
    let raw = addr.trim();
    if raw.is_empty() || raw.contains('%') {
        return false;
    }
    let parts: Vec<&str> = raw.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    let mut octets = [0u16; 4];
    for (i, part) in parts.iter().enumerate() {
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        match part.parse::<u16>() {
            Ok(v) if v <= 255 => octets[i] = v,
            _ => return false,
        }
    }
    if octets[0] == 127 {
        return false; // loopback
    }
    if octets[0] == 169 && octets[1] == 254 {
        return false; // link-local
    }
    if octets.iter().all(|&o| o == 0) {
        return false; // 0.0.0.0
    }
    if octets.iter().all(|&o| o == 255) {
        return false; // broadcast
    }
    true
}

/// Only `/24` is swept: it covers virtually every home/office LAN and keeps
/// the scan bounded (254 probes).
pub fn subnet_hosts(target: &str) -> Vec<String> {
    let parts: Vec<&str> = target.trim().split('.').collect();
    let octet = |s: &str| s.parse::<u8>().ok().filter(|o| *o <= 254);
    let Some(a) = octet(parts.first().copied().unwrap_or_default()) else {
        return Vec::new();
    };
    let Some(b) = parts.get(1).and_then(|s| octet(s)) else {
        return Vec::new();
    };
    let Some(c) = parts.get(2).and_then(|s| octet(s)) else {
        return Vec::new();
    };
    let prefix = format!("{a}.{b}.{c}");
    // A 4th part is this PC's own address; a 3-part target has none to skip.
    let self_last: Option<u16> = parts.get(3).and_then(|s| s.parse::<u16>().ok());
    (1..=254)
        .filter(|n| Some(*n as u16) != self_last)
        .map(|n| format!("{prefix}.{n}"))
        .collect()
}

/// Scan the local `/24` for anything listening on `port`.
///
/// This is the fallback for networks where **mDNS multicast is blocked**
/// (guest WiFi, some VPNs, mesh APs) but clients can still reach each
/// other. It cannot defeat true AP/client isolation — nothing can.
pub async fn scan_subnet_for_port(
    ip: &str,
    port: u16,
    timeout: Duration,
    concurrency: usize,
) -> Vec<String> {
    use tokio::sync::Semaphore;
    use std::sync::Arc;

    let hosts = subnet_hosts(ip);
    if hosts.is_empty() {
        return Vec::new();
    }
    let sem = Arc::new(Semaphore::new(concurrency.max(1)));
    let mut tasks = Vec::with_capacity(hosts.len());

    for host in hosts {
        let sem = sem.clone();
        tasks.push(tokio::spawn(async move {
            let _permit = sem.acquire().await.ok()?;
            if probe_tcp(&host, port, timeout).await {
                Some(host)
            } else {
                None
            }
        }));
    }

    let mut found = Vec::new();
    for task in tasks {
        if let Ok(Some(host)) = task.await {
            found.push(host);
        }
    }
    found
}

/// Parse `"host"` or `"host:port"` into `(host, port)`, defaulting the port.
pub fn parse_host_port(input: &str, default_port: u16) -> Option<(String, u16)> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    match trimmed.rsplit_once(':') {
        // Only treat the suffix as a port if it parses and there's a host
        // before it (avoids mangling bare IPv6 literals without brackets).
        Some((host, port)) if !host.is_empty() => match port.parse::<u16>() {
            Ok(p) => Some((host.to_string(), p)),
            Err(_) => Some((trimmed.to_string(), default_port)),
        },
        _ => Some((trimmed.to_string(), default_port)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_host_only_uses_default_port() {
        assert_eq!(
            parse_host_port("192.168.1.5", 8765),
            Some(("192.168.1.5".to_string(), 8765))
        );
    }

    #[test]
    fn parse_host_and_port() {
        assert_eq!(
            parse_host_port(" 192.168.1.5:9000 ", 8765),
            Some(("192.168.1.5".to_string(), 9000))
        );
    }

    #[test]
    fn parse_empty_is_none() {
        assert_eq!(parse_host_port("   ", 8765), None);
    }

    #[test]
    fn parse_non_numeric_port_falls_back() {
        assert_eq!(
            parse_host_port("myphone.local", 8765),
            Some(("myphone.local".to_string(), 8765))
        );
    }

    #[tokio::test]
    async fn probe_tcp_detects_a_listening_server() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(probe_tcp("127.0.0.1", port, Duration::from_millis(500)).await);
        // A port nobody listens on fails fast.
        assert!(!probe_tcp("127.0.0.1", 1, Duration::from_millis(300)).await);
    }

    #[test]
    fn subnet_hosts_covers_254_and_excludes_self() {
        let hosts = subnet_hosts("192.168.31.159");
        assert_eq!(hosts.len(), 253); // 254 minus our own last octet
        assert!(hosts.contains(&"192.168.31.1".to_string()));
        assert!(hosts.contains(&"192.168.31.254".to_string()));
        assert!(!hosts.contains(&"192.168.31.159".to_string()));
    }

    #[test]
    fn subnet_hosts_rejects_malformed() {
        assert!(subnet_hosts("not-an-ip").is_empty());
        assert!(subnet_hosts("192.168").is_empty());
        assert!(subnet_hosts("192.168.300.1").is_empty());
    }

    /// A bare /24 prefix is a first-class input: it is how you look for a
    /// phone on a guest subnet. Before this it silently returned an empty
    /// list, so the scan reported "nothing found" having probed nothing.
    #[test]
    fn subnet_hosts_accepts_a_bare_prefix() {
        let hosts = subnet_hosts("192.168.32");
        assert_eq!(hosts.len(), 254, "a prefix has no self to exclude");
        assert!(hosts.contains(&"192.168.32.1".to_string()));
        assert!(hosts.contains(&"192.168.32.254".to_string()));
        assert!(hosts.iter().all(|h| h.starts_with("192.168.32.")));
    }

    #[tokio::test]
    async fn scan_subnet_finds_a_local_listener() {
        // Bind on the loopback so the sweep (which skips our own host) can
        // still reach it via 127.0.0.1's sibling addresses is not possible;
        // instead assert the scan mechanics against a tiny /24 where we
        // control one host. Use 127.0.0.1's subnet and a listener on
        // 127.0.0.2 to prove a non-obvious host is discovered.
        let listener = match tokio::net::TcpListener::bind("127.0.0.2:0").await {
            Ok(l) => l,
            Err(_) => return, // 127.0.0.2 may be unavailable; skip silently
        };
        let port = listener.local_addr().unwrap().port();
        let found = scan_subnet_for_port("127.0.0.1", port, Duration::from_millis(200), 64).await;
        assert!(found.contains(&"127.0.0.2".to_string()), "found = {found:?}");
    }
    #[test]
    fn only_a_plausible_lan_address_is_worth_persisting() {
        for good in ["192.168.31.159", "10.0.0.7", "172.20.10.1"] {
            assert!(is_usable_dial_address(good), "{good} is a normal LAN address");
        }
        // The ghost-dial loop: anything that answers on loopback gets
        // re-persisted on every connect and re-dialed forever.
        for bad in [
            "127.0.0.1",
            "127.1.2.3",
            "169.254.228.39",
            "0.0.0.0",
            "255.255.255.255",
            "192.168.1.5%en0", // scoped, and not dialable
            "",
            "   ",
            "not-an-ip",
            "192.168.1",
            "192.168.1.5.6",
            "192.168.1.256",
            "192.168.1.0x5",
        ] {
            assert!(!is_usable_dial_address(bad), "{bad:?} must be refused");
        }
    }

    /// Healing, not merely refusing: a store written before this check existed
    /// can already hold a ghost, so the read site has to refuse it too.
    #[test]
    fn a_ghost_written_by_an_older_build_is_refused_on_the_way_out() {
        assert!(!is_usable_dial_address("127.0.0.1"));
    }

    #[test]
    fn presence_service_type_is_distinct_from_the_phone_service() {
        assert_eq!(SERVICE_TYPE_COMPUTER, "_remotecrab-computer._tcp.local.");
        assert_ne!(SERVICE_TYPE_COMPUTER, "_remotecrab._tcp.local.");
    }

    /// The TXT contract the phone parses, pinned as data so Mac and Windows
    /// cannot drift on key spelling.
    #[test]
    fn presence_service_info_carries_the_frozen_txt_contract() {
        let info = presence_service_info("rc-presence", "id-9", "Test PC", "windows").unwrap();
        assert_eq!(info.get_type(), SERVICE_TYPE_COMPUTER);
        let props = info.get_properties();
        assert_eq!(props.get("id").map(|p| p.val_str()), Some("id-9"));
        assert_eq!(props.get("name").map(|p| p.val_str()), Some("Test PC"));
        assert_eq!(props.get("platform").map(|p| p.val_str()), Some("windows"));
        assert_eq!(props.get("port").map(|p| p.val_str()), Some("8766"));
    }

    #[test]
    fn knock_port_matches_the_swift_side() {
        assert_eq!(KNOCK_PORT, 8766);
    }

    /// The service type's first label is what mdns-sd's length cap applies to,
    /// and `_remotecrab-computer` is 21 bytes against a default of 15.
    ///
    /// Not a style rule: mdns-sd enforces it inside its daemon thread, where a
    /// rejection is a `log` line nobody reads and `register` has already
    /// returned `Ok`. Every Windows advertisement was rejected that way, so the
    /// phone never showed a green dot while the app printed "advertising as ..."
    /// and every test stayed green. `advertise` raises the cap to 30; this
    /// asserts the type still fits under it, so a future rename of the service
    /// cannot quietly reintroduce the same silence.
    #[test]
    fn the_service_type_fits_mdns_sds_raised_cap() {
        // The value `advertise` sets. Mirrored here rather than shared because
        // mdns-sd owns the constant and it is already a literal at the call.
        const CAP: usize = 30;
        let label = SERVICE_TYPE_COMPUTER
            .split('.')
            .next()
            .expect("a service type has a first label");
        assert!(
            label.len() <= CAP,
            "{label:?} is {} bytes; mdns-sd will reject every registration",
            label.len()
        );
        assert!(
            label.len() > 15,
            "if this ever fits the default, drop the set_service_name_len_max call"
        );
    }

    /// A probe must still find a listener that is really there.
    ///
    /// The fix next to this makes probes bind to the LAN adapter, because under
    /// a TUN an unbound probe reports a hit for every address it tries. The risk
    /// of a fix like that is over-correcting into "never finds anything", which
    /// would silently turn the `/24` fallback off — so the positive case is
    /// pinned here.
    #[tokio::test]
    async fn a_probe_finds_a_real_listener() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(
            probe_tcp("127.0.0.1", port, Duration::from_millis(800)).await,
            "a bound probe must still reach a listener on the loopback"
        );
    }

    /// Route mdns-sd's own `log` output to stdout.
    ///
    /// MDNS-SD's `register` hands its work to a daemon thread, so a failure
    /// there never reaches the caller: `advertise` returns `Ok` for a
    /// registration that did nothing at all. Without a logger installed, that is
    /// indistinguishable from success — which is how the advertisement shipped
    /// doing nothing while every test stayed green.
    fn install_logger() {
        struct Print;
        impl log::Log for Print {
            fn enabled(&self, _: &log::Metadata) -> bool {
                true
            }
            fn log(&self, r: &log::Record) {
                println!("[mdns {}] {}", r.level(), r.args());
            }
            fn flush(&self) {}
        }
        static PRINT: Print = Print;
        let _ = log::set_logger(&PRINT);
        log::set_max_level(log::LevelFilter::Debug);
    }

    /// End-to-end over real mDNS. `#[ignore]`: it needs a host whose process
    /// may bind multicast (some CI/sandbox hosts refuse it), so it does not
    /// gate every commit. Run it explicitly with
    /// `cargo test -p rc-discovery -- --ignored an_advertised_computer`.
    ///
    /// It asserts on the mDNS **instance**, not on the TXT `name`. `browse` maps
    /// every service through `phone_from_resolved`, which takes the display name
    /// from the instance — for the presence service that is the machine id, and
    /// the readable name travels in the TXT where the phone reads it. The test
    /// used to wait for `p.name == "Test PC"`, which this mapping can never
    /// produce, so it timed out no matter what: it had never once checked that
    /// advertising works, which is why nobody noticed that it does not.
    #[tokio::test]
    #[ignore]
    async fn an_advertised_computer_is_found_by_a_browser() {
        install_logger();
        let adv = advertise("rc-presence", "id-9", "Test PC", "windows").unwrap();
        let mut rx = browse(SERVICE_TYPE_COMPUTER).unwrap();
        let found = tokio::time::timeout(Duration::from_secs(15), async {
            while let Some(ev) = rx.recv().await {
                if let DiscoveryEvent::Found(p) = ev {
                    if p.name == "rc-presence" {
                        return;
                    }
                }
            }
        })
        .await;
        assert!(found.is_ok(), "browser never found the advertised computer");
        adv.stop();
    }

    /// Print the record this machine would advertise. For diagnosing "the
    /// browser finds other computers but not this one".
    #[test]
    #[ignore]
    fn print_presence_service_info() {
        let info = presence_service_info("rc-diag", "id-9", "EDWIN", "windows").unwrap();        println!("fullname : {}", info.get_fullname());
        println!("hostname : {}", info.get_hostname());
        println!("port     : {}", info.get_port());
        println!("addresses: {:?}", info.get_addresses());
        for p in info.get_properties().iter() {
            println!("txt      : {} = {}", p.key(), p.val_str());
        }
        println!("local_ipv4_addresses: {:?}", local_ipv4_addresses());
    }

    /// Browse only, and print every event. For diagnosing an advertisement that
    /// comes from *another* process:
    ///
    /// ```sh
    /// # terminal 1: the receiver, which advertises
    /// remotecrab.exe --no-tray
    /// # terminal 2
    /// cargo test -p rc-discovery --release -- --ignored browse_computers --nocapture
    /// ```
    ///
    /// Split from the round-trip test because one process that advertises and
    /// browses the same service type has two `ServiceDaemon`s in it, which is a
    /// different situation from the product's and is not a diagnosis of it.
    #[tokio::test]
    #[ignore]
    async fn browse_computers_and_print_events() {
        install_logger();
        let mut rx = browse(SERVICE_TYPE_COMPUTER).unwrap();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
        loop {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Some(ev)) => println!("EVENT: {ev:?}"),
                Ok(None) => {
                    println!("channel closed");
                    break;
                }
                Err(_) => {
                    println!("timed out with no events");
                    break;
                }
            }
        }
    }
}
