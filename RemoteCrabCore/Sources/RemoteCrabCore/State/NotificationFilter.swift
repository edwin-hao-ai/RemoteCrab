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
}
