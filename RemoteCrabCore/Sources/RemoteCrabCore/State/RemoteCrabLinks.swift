import Foundation

/// Canonical public URLs for RemoteCrab.
///
/// The marketing site, the Mac receiver download and the privacy policy
/// all live under the VGO studio domain (`vgoapp.com/remotecrab/`) rather
/// than a separate `remotecrab.app` site. Single source of truth so the
/// iOS app, the Mac app and the store metadata never drift apart.
public enum RemoteCrabLinks {
    /// Product page: what RemoteCrab does + the Mac receiver download.
    public static let productPage = "https://vgoapp.com/remotecrab/"
    /// Direct Mac receiver installer (stable alias, refreshed each release).
    public static let macDownload = "https://vgoapp.com/downloads/RemoteCrab.dmg"
    /// Privacy policy (App Store listing + in-app "Privacy Policy" row).
    public static let privacyPolicy = "https://vgoapp.com/remotecrab/privacy/"
    /// Source repository.
    public static let github = "https://github.com/edwin-hao-ai/RemoteCrab"
}
