import Foundation
import Network

/// One way to reach a computer, in a dial order.
///
/// The phone dials a tapped computer's Bonjour endpoint first. On a TUN/VPN or
/// client-isolated network mDNS resolves but the `.local`/SRV address does not
/// route (design §12); the same computer's last-known IPv4 on the LAN usually
/// still does. `ordered(bonjour:remembered:)` is the whole rule — Bonjour
/// first, remembered IPs next, de-duplicated — so the dial can try candidates
/// in order instead of betting everything on one endpoint. A future relay is
/// one more case here, which is why the retry iterates this type.
public enum ComputerAddress: Sendable, Equatable {
    /// A Bonjour-discovered endpoint (a service, resolved by Network.framework).
    case bonjour(NWEndpoint)
    /// A literal host or `.local` name with an explicit port.
    case host(String, UInt16)

    /// The dialable endpoint. A `UInt16` is the whole port range, so the
    /// conversion always succeeds.
    public var endpoint: NWEndpoint {
        switch self {
        case .bonjour(let endpoint):
            return endpoint
        case .host(let host, let port):
            return .hostPort(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!)
        }
    }

    /// Bonjour candidates first, then remembered addresses not already offered,
    /// each group in the order given. Stable, so caller priority is preserved.
    public static func ordered(bonjour: [ComputerAddress],
                               remembered: [ComputerAddress]) -> [ComputerAddress] {
        var out: [ComputerAddress] = []
        for candidate in bonjour + remembered where !out.contains(candidate) {
            out.append(candidate)
        }
        return out
    }

    /// How long one candidate may sit before the next is tried. The same budget
    /// the receiver's dial watchdog uses: a Bonjour endpoint that does not route
    /// would otherwise hold the whole attempt for the system TCP timeout.
    public static let dialBudget: TimeInterval = 8
}
