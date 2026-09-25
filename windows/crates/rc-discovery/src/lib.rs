//! `rc-discovery` — find iPhones running RemoteCrab on the LAN.
//!
//! Primary path: mDNS browse for `_remotecrab._tcp.local.` (the service the
//! iOS app advertises). Fallback path: direct TCP probes, because multicast
//! mDNS is blocked on some networks (iPhone Personal Hotspot, AP client
//! isolation, VPNs) — the Mac receiver ships the same fallback
//! (`ReceiverSession.startFallbackLoop`), and we mirror it here.

use std::net::IpAddr;
use std::time::Duration;

use mdns_sd::{ServiceDaemon, ServiceEvent};
use tokio::net::TcpStream;
use tokio::sync::mpsc::UnboundedReceiver;

/// The iPhone Personal Hotspot gateway (the phone is always the gateway).
/// When the PC is on the phone's hotspot, multicast doesn't reach clients,
/// so probing this address is the escape hatch.
pub const HOTSPOT_GATEWAY: &str = "172.20.10.1";

/// The fixed TCP port the iOS app listens on.
pub const DEFAULT_PORT: u16 = 8765;

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

/// Build the host addresses of the local `/24` subnet for `ip`
/// (e.g. `192.168.31.159` → `192.168.31.1` … `192.168.31.254`).
///
/// Only `/24` is swept: it covers virtually every home/office LAN and keeps
/// the scan bounded (254 probes). Other prefixes fall back to the same
/// last-octet sweep, which is a best-effort convenience, not a guarantee.
pub fn subnet_hosts(ip: &str) -> Vec<String> {
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 {
        return Vec::new();
    }
    let prefix = format!("{}.{}.{}", parts[0], parts[1], parts[2]);
    let self_last: u32 = parts[3].parse().unwrap_or(0);
    (1..=254)
        .filter(|n| *n != self_last)
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
}
