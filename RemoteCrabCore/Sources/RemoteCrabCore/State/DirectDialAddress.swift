import Foundation

/// Whether an address is a legitimate **direct-dial** candidate for the
/// iPhone, and whether it may be remembered as "the last phone IP".
///
/// The receiver learns the phone's IPv4 from every successful TCP connect and
/// re-dials it when Bonjour comes up empty. That is only safe if the address
/// can actually be a phone on the LAN — a loopback or link-local address is
/// not, and persisting one creates a self-reinforcing loop: the fallback dials
/// the bogus address, "succeeds" against whatever happens to listen there
/// (a simulator's own listener on 127.0.0.1:8765, observed in practice), and
/// that connect re-persists the same bogus address. The symptom is exactly
/// "it connects sometimes and to the wrong thing".
public enum DirectDialAddress {

    /// True when `ip` is a dotted-quad IPv4 that could be the phone.
    ///
    /// Rejected, with reasons:
    /// - empty / not a dotted quad → cannot be dialed
    /// - `127.0.0.0/8` — loopback (the simulator case)
    /// - `169.254.0.0/16` — link-local / self-assigned (an unreachable AWDL
    ///   or half-configured interface, also observed in the wild)
    /// - `0.0.0.0`, and `255.255.255.255`
    /// - a `%en0`-style scope suffix — `NWEndpoint` cannot dial that form,
    ///   and it is what `currentPath.remoteEndpoint` sometimes prints
    public static func isUsable(_ ip: String) -> Bool {
        let raw = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("%") else { return false }

        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
                return false
            }
            octets.append(value)
        }

        if octets[0] == 127 { return false }                      // loopback
        if octets[0] == 169 && octets[1] == 254 { return false }  // link-local
        if octets.allSatisfy({ $0 == 0 }) { return false }        // 0.0.0.0
        if octets.allSatisfy({ $0 == 255 }) { return false }      // broadcast
        return true
    }
}
