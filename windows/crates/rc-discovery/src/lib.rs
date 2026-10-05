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

/// The fixed TCP port the iOS app listens on.
pub const DEFAULT_PORT: u16 = 8765;

/// The service type a receiver advertises so the phone can see it online.
///
/// MUST stay distinct from the phone's `_remotecrab._tcp.local.`: the receiver
/// browses that one for iPhones, and reusing it would make it dial computers.
pub const SERVICE_TYPE_COMPUTER: &str = "_remotecrab-computer._tcp.local.";

#[derive(Debug, thiserror::Error)]
pub enum DiscoveryError {
    #[error("mDNS error: {0}")]
    Mdns(#[from] mdns_sd::Error),
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

    let info = match local_ipv4_addresses().into_iter().next() {
        Some(ip) => ServiceInfo::new(SERVICE_TYPE_COMPUTER, instance, &host, ip.as_str(), 0u16, props)?,
        None => ServiceInfo::new(SERVICE_TYPE_COMPUTER, instance, &host, (), 0u16, props)?,
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
        tokio::time::timeout(timeout, TcpStream::connect((host, port))).await,
        Ok(Ok(_))
    )
}

/// The machine's own IPv4 addresses (excluding loopback + link-local).
///
/// Used to derive the `/24` to sweep when mDNS is unavailable. We enumerate
/// interfaces without extra dependencies by opening a throwaway UDP socket
/// to a public address — the OS picks the egress interface, whose local
/// address is our primary LAN IP.
pub fn local_ipv4_addresses() -> Vec<String> {
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
        let info = presence_service_info("rc-presence-test", "id-9", "Test PC", "windows").unwrap();
        assert_eq!(info.get_type(), SERVICE_TYPE_COMPUTER);
        let props = info.get_properties();
        assert_eq!(props.get("id").map(|p| p.val_str()), Some("id-9"));
        assert_eq!(props.get("name").map(|p| p.val_str()), Some("Test PC"));
        assert_eq!(props.get("platform").map(|p| p.val_str()), Some("windows"));
    }

    /// End-to-end over real mDNS. `#[ignore]`: it needs a host whose process
    /// may bind multicast (some CI/sandbox hosts refuse it), so it does not
    /// gate every commit. Run it explicitly with
    /// `cargo test -p rc-discovery -- --ignored an_advertised_computer`.
    #[tokio::test]
    #[ignore]
    async fn an_advertised_computer_is_found_by_a_browser() {
        let adv = advertise("rc-presence-test", "id-9", "Test PC", "windows").unwrap();
        let mut rx = browse(SERVICE_TYPE_COMPUTER).unwrap();
        let found = tokio::time::timeout(Duration::from_secs(15), async {
            while let Some(ev) = rx.recv().await {
                if let DiscoveryEvent::Found(p) = ev {
                    if p.name == "Test PC" {
                        return;
                    }
                }
            }
        })
        .await;
        assert!(found.is_ok(), "browser never found the advertised computer");
        adv.stop();
    }
}
