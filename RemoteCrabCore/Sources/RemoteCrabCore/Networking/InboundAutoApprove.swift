import Foundation

/// Headless-test opt-in for the receiver's first-contact prompt.
///
/// When an **unpaired** phone first connects over the inbound
/// (phone-initiated) path, `InboundGrantPolicy` holds the connection and the
/// Mac asks its user to confirm. A device e2e has no one to click that prompt,
/// so it launches the receiver with `REMOTECRAB_E2E_AUTO_APPROVE_INBOUND=1` and
/// the receiver approves the pending first contact the moment it is raised —
/// mirroring `REMOTECRAB_E2E_AUTOPAIR` on the iOS side.
///
/// The gate is deliberately strict (`== "1"`): anything else, including the
/// presence of the key with another value, is inert, so production (which never
/// sets it) always waits for a human.
public enum InboundAutoApprove {
    public static let environmentKey = "REMOTECRAB_E2E_AUTO_APPROVE_INBOUND"

    public static func isEnabled(in environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}
