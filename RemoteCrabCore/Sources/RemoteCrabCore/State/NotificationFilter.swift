import Foundation

/// Decides whether a captured Mac notification may be relayed to the
/// iPhone. Pure so the policy is unit-tested. Denylist-first: the user
/// asked to exclude privacy-sensitive apps and allow everything else
/// (we can't know what apps they install). App names are localized
/// strings with no bundle id, so matching is case-insensitive substring
/// on the display name (see the design's hard limits).
public struct NotificationFilter: Sendable {
    public static let defaultDenylist: [String] = [
        // Password managers / auth
        "1Password", "Keychain", "钥匙串", "Bitwarden", "LastPass", "Authy", "验证码",
        // Messaging / social
        "Messages", "信息", "Mail", "邮件", "WeChat", "微信", "Telegram",
        "WhatsApp", "Signal", "QQ",
        // Finance / banking
        "银行", "Bank", "支付宝", "Alipay", "微信支付", "PayPal", "Wallet", "钱包",
    ]

    public let denylist: [String]

    public init(denylist: [String] = NotificationFilter.defaultDenylist) {
        self.denylist = denylist
    }

    public func shouldRelay(app: String) -> Bool {
        let a = app.lowercased()
        return !denylist.contains { !$0.isEmpty && a.contains($0.lowercased()) }
    }

    /// Deny when either the parsed app name **or** the raw banner
    /// description matches.
    ///
    /// The description check is deliberate: the source app name is a
    /// heuristic (`NotificationBannerParsing.appName`) that falls back to the
    /// whole description when it cannot find a clean cut, and the denylist is
    /// the only confidentiality control on a cleartext link. An unparseable
    /// banner must therefore fail **closed** — worse to relay a private
    /// message with a mangled app name than to drop a benign banner.
    public func shouldRelay(app: String, description: String) -> Bool {
        shouldRelay(app: app) && shouldRelay(app: description)
    }
}
