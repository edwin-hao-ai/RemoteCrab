import XCTest
@testable import RemoteCrabCore

/// Wire round-trips for the Mac → iPhone app switcher frames.
final class AppSwitcherWireTests: XCTestCase {

    func testRoundTripAppList() throws {
        let apps = [
            IBAppInfo(id: "com.apple.Safari", name: "Safari", pid: 123, isActive: true,
                      iconPNG: Data([0x89, 0x50, 0x4E, 0x47])),
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

    func testRoundTripQuitAppGraceful() throws {
        let encoded = try IBWire.encode(quitApp: IBQuitApp(id: "com.apple.Terminal"))
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .quitApp)
        let decoded = try IBWire.decodeQuitApp(frames[0])
        XCTAssertEqual(decoded.id, "com.apple.Terminal")
        XCTAssertFalse(decoded.force)
    }

    func testRoundTripQuitAppForced() throws {
        let encoded = try IBWire.encode(quitApp: IBQuitApp(id: "pid:789", force: true))
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .quitApp)
        let decoded = try IBWire.decodeQuitApp(frames[0])
        XCTAssertEqual(decoded.id, "pid:789")
        XCTAssertTrue(decoded.force)
    }

    func testRoundTripWindowListRequest() throws {
        let encoded = try IBWire.encode(windowListRequest: IBWindowListRequest())
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .windowListRequest)
        XCTAssertNoThrow(try IBWire.decodeWindowListRequest(frames[0]))
    }

    func testRoundTripWindowList() throws {
        let windows = [
            IBWindowInfo(id: "123:45", appId: "com.apple.Terminal", appName: "Terminal",
                         title: "Claude Code — 等待确认", isActive: true,
                         width: 1200, height: 760,
                         snapshotJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            IBWindowInfo(id: "456:7", appId: "com.apple.Safari", appName: "Safari",
                         title: "RemoteCrab", isActive: false, width: 1440, height: 900)
        ]
        let encoded = try IBWire.encode(windowList: IBWindowList(windows: windows, canCapture: true))
        let frames = IBWire.Parser().append(encoded)

        XCTAssertEqual(frames[0].kind, .windowList)
        let decoded = try IBWire.decodeWindowList(frames[0])
        XCTAssertEqual(decoded.windows, windows)
        XCTAssertTrue(decoded.canCapture)
    }

    func testRoundTripWindowListDegraded() throws {
        // No Screen Recording: one app-level entry per app, no titles/pixels.
        let windows = [
            IBWindowInfo(id: "com.apple.Terminal", appId: "com.apple.Terminal",
                         appName: "Terminal", title: "", isActive: true)
        ]
        let encoded = try IBWire.encode(windowList: IBWindowList(windows: windows, canCapture: false))
        let frames = IBWire.Parser().append(encoded)

        let decoded = try IBWire.decodeWindowList(frames[0])
        XCTAssertFalse(decoded.canCapture)
        XCTAssertEqual(decoded.windows.first?.snapshotJPEG, nil)
        XCTAssertEqual(decoded.windows.first?.title, "")
    }
}
