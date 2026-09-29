//! `--scan`: sweep a /24 for the iPhone's port 鈥?the diagnostic for
//! "mDNS found nothing".

use std::process::ExitCode;

/// `--scan [<subnet-prefix>]` — sweep a /24 for the iPhone's port.
///
/// Without an argument it scans this PC's own LANs. With one it scans that
/// network instead, which is how you look for a phone parked on a guest or
/// IoFi subnet the router routes but isolates.
pub async fn run_scan(subnet: Option<&str>) -> ExitCode {
    let port = rc_net::DEFAULT_PORT;
    let ips: Vec<String> = match subnet {
        Some(s) => vec![s.to_string()],
        None => rc_discovery::local_ipv4_addresses(),
    };
    if ips.is_empty() {
        eprintln!("Could not determine this PC's LAN address (are you online?)");
        return ExitCode::from(1);
    }
    if subnet.is_none() {
        println!("This PC's LAN address(es): {}", ips.join(", "));
    }

    let mut any = false;
    for ip in &ips {
        let hosts = rc_discovery::subnet_hosts(ip);
        if hosts.is_empty() {
            println!("  {ip}: not a usable /24 — skipped (expected 192.168.31 or 192.168.31.159)");
            continue;
        }
        println!(
            "Scanning {}/24 for port {port} ({} hosts, ~{}s) …",
            hosts[0].rsplit_once('.').map(|(p, _)| p).unwrap_or(ip),
            hosts.len(),
            4
        );
        let found = rc_discovery::scan_subnet_for_port(
            ip,
            port,
            std::time::Duration::from_millis(1200),
            128,
        )
        .await;
        if found.is_empty() {
            println!("  no device on {port} found in this subnet");
        } else {
            any = true;
            for host in found {
                println!("  FOUND  {host}:{port}");
                println!("         → connect with:  remotecrab --connect {host}:{port}");
            }
        }
    }

    if !any {
        println!(
            "\nNothing found. Likely causes, in order:\n\
             \x20 1. The iPhone's RemoteCrab app is not open + streaming\n\
             \x20 2. The iPhone is on a different WiFi / band\n\
             \x20 3. This router has AP isolation ON (clients can't see each other)\n\
             \x20    → turn off 'AP isolation / wireless isolation' in the router settings"
        );
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

