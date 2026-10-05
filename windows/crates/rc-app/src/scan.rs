//! `--scan`: sweep a /24 for the iPhone's port 鈥?the diagnostic for
//! "mDNS found nothing".

use std::process::ExitCode;

use crate::i18n::t;

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
        eprintln!("{}", t("无法确定本机的局域网地址（是本机没联网吗？）", "Could not determine this PC's LAN address (are you online?)"));
        return ExitCode::from(1);
    }
    if subnet.is_none() {
        println!("{} {}", t("本机局域网地址：", "This PC's LAN address(es):"), ips.join(", "));
    }

    let mut any = false;
    for ip in &ips {
        let hosts = rc_discovery::subnet_hosts(ip);
        if hosts.is_empty() {
            println!("  {ip}: {}", t("不是可用的 /24 —— 已跳过", "not a usable /24 — skipped"));
            continue;
        }
        println!(
            "{} {}/24 {} {port} ({} hosts, ~{}s) …",
            t("正在扫描", "Scanning"),
            hosts[0].rsplit_once('.').map(|(p, _)| p).unwrap_or(ip),
            t("查找端口", "for port"),
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
            println!("  {}", t(&format!("本网段没有设备监听 {port}"), &format!("no device on {port} found in this subnet")));
        } else {
            any = true;
            for host in found {
                println!("  FOUND  {host}:{port}");
                println!("         {}", t(&format!("→ 连接： remotecrab --connect {host}:{port}"), &format!("→ connect with:  remotecrab --connect {host}:{port}")));
            }
        }
    }

    if !any {
        println!(
            "\n{}",
            t(
                "什么都没找到。可能的原因，按可能性排序：\n\
                 \x20 1. iPhone 上的 RemoteCrab 没有打开「开始推流」\n\
                 \x20 2. iPhone 连的是另一个 WiFi / 另一个频段\n\
                 \x20 3. 路由器开了 AP 隔离（客户端之间互相不可见）\n\
                 \x20    → 在路由器设置里关掉「AP 隔离 / 无线隔离」",
                "Nothing found. Likely causes, in order:\n\
                 \x20 1. The iPhone's RemoteCrab app is not open + streaming\n\
                 \x20 2. The iPhone is on a different WiFi / band\n\
                 \x20 3. This router has AP isolation ON (clients can't see each other)\n\
                 \x20    → turn off 'AP isolation / wireless isolation' in the router settings",
            )
        );
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}
