import XCTest
@testable import RemoteCrabCore

final class ExtensionSettingsURLTests: XCTestCase {
    func testNoFabricatedAnchors() {
        for url in ExtensionSettingsURL.paneCandidates {
            XCTAssertFalse(url.absoluteString.contains("?CameraExtensions"),
                           "Apple 无受支持深链到某个扩展分类；臆造锚点会让 NSWorkspace.open 假成功")
            XCTAssertTrue(url.absoluteString.contains("LoginItems-Settings")
                          || url.absoluteString.contains("Extensions"),
                          "只允许登录项与扩展相关 pane")
        }
    }
    func testMostSpecificPaneComesFirst() {
        XCTAssertTrue(ExtensionSettingsURL.paneCandidates.first?
            .absoluteString.contains("LoginItems-Settings") ?? false)
    }
}
