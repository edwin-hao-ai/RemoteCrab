import XCTest
@testable import iBridgeCore

/// Wire round-trips for the Mac → iPhone app switcher frames.
final class AppSwitcherWireTests: XCTestCase {

    func testRoundTripAppList() throws {
        let apps = [
            IBAppInfo(id: "com.apple.Safari", name: "Safari", pid: 123, isActive: true),
            IBAppInfo(id: "com.apple.dt.Xcode", name: "Xcode", pid: 456, isActive: false),
            IBAppInfo(id: "pid:789", name: "Helper", pid: 789, isActive: false)
        ]
        let encoded = try IBWire.encode(appList: IBAppList(apps: apps))
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .appList)
        XCTAssertEqual(try IBWire.decodeAppList(frames[0]).apps, apps)
    }

    func testRoundTripAppListRequest() throws {
        let encoded = try IBWire.encode(appListRequest: IBAppListRequest())
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .appListRequest)
        XCTAssertNoThrow(try IBWire.decodeAppListRequest(frames[0]))
    }

    func testRoundTripActivateApp() throws {
        let encoded = try IBWire.encode(activateApp: IBActivateApp(id: "com.apple.Terminal"))
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .activateApp)
        XCTAssertEqual(try IBWire.decodeActivateApp(frames[0]).id, "com.apple.Terminal")
    }
}
