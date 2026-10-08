import Foundation

/// macOS「登录项与扩展」pane 的候选深链，按可靠度排序。
///
/// 只放**受支持**的 pane：Apple 没有深链能跳到某个具体扩展分类
/// （开发者论坛 thread 765970），所以 `CameraExtensions` 这类锚点是臆造——
/// 而 `NSWorkspace.open` 对无效锚点也返回 true，会让 fallback 永不执行
/// （lesson 159）。这里刻意不包含任何锚点。
public enum ExtensionSettingsURL {
    public static var paneCandidates: [URL] {
        var urls: [URL] = []
        // 最精确：登录项与扩展
        urls.append(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        // 旧的扩展 pane（较老系统）
        urls.append(URL(string: "x-apple.systempreferences:com.apple.preferences.Extensions")!)
        return urls
    }
}
