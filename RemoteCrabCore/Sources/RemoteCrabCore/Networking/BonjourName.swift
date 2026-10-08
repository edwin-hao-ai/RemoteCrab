import Foundation

/// Bonjour appends a `" (2)"`, `" (3)"`, … suffix to a service instance name
/// that collides with one already on the link. The receiver keys its
/// phone-initiated identity map by the **base** name, so a collided instance
/// must be normalised back before the lookup or a phone that dials itself is
/// mistaken for a legacy phone and gets dialed by the receiver (the race the
/// phone-initiated design exists to remove).
public enum BonjourName {
    /// Strip a trailing `" (N)"` collision suffix. A name that does not carry
    /// one — including a name that genuinely ends in something else in
    /// parentheses — is returned unchanged.
    public static func base(_ name: String) -> String {
        guard name.hasSuffix(")") else { return name }
        guard let open = name.lastIndex(of: "(") else { return name }
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return name }
        let before = name[..<open]
        guard before.hasSuffix(" ") else { return name }
        return String(before.dropLast())
    }
}
