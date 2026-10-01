import XCTest
@testable import RemoteCrabCore

/// The launcher frame is one message carrying an icon per app, and it is the
/// only thing that made "Open App…" slow. Two things must hold, and one of
/// them was learned the hard way: the icon has to stay **PNG**.
///
/// JPEG is 12× smaller and was tried. It has no alpha channel, a macOS icon
/// is a squircle with transparent corners, so the encoder fills them with
/// opaque white and the phone draws a white square behind every tile. These
/// tests exist so that optimisation is never attempted again blind, and so
/// the size win is pinned where it was actually won — the pixel axis.
final class InstalledAppsWireTests: XCTestCase {

    private func frame(_ apps: [IBInstalledApp]) throws -> IBWire.Frame {
        let data = try IBWire.encode(installedApps: IBInstalledApps(apps: apps))
        let frames = IBWire.Parser().append(data)
        return try XCTUnwrap(frames.first { $0.kind == .installedApps })
    }

    func testRoundTrip() throws {
        let icon = Data(repeating: 0x89, count: 512)
        let apps = [
            IBInstalledApp(id: "com.apple.Safari", name: "Safari", iconPNG: icon),
            IBInstalledApp(id: "com.apple.Notes", name: "Notes"),
        ]
        XCTAssertEqual(try IBWire.decodeInstalledApps(try frame(apps)).apps, apps)
    }

    /// The field stays optional in the decode direction. It must never be
    /// defaulted to empty `Data`: that is truthy to a `UIImage(data:)`
    /// check and would read as a corrupt icon rather than a missing one.
    func testAPayloadWithNoIconKeyStillDecodes() throws {
        let json = #"{"apps":[{"id":"com.apple.Safari","name":"Safari"}]}"#
        let decoded = try IBWire.decodeInstalledApps(
            IBWire.Frame(kind: .installedApps, payload: Data(json.utf8)))
        XCTAssertEqual(decoded.apps.count, 1)
        XCTAssertNil(decoded.apps[0].iconPNG)
    }

    /// Pins the size win where it was actually won.
    ///
    /// 113 apps is a real `/Applications` on a real Mac. The old shape —
    /// `NSImage.lockFocus` into a "96 pt" box, which the backing scale turned
    /// into 192×192 at ~94 KB each — cost a single **14.25 MB** frame. The
    /// shipped shape is a 128 px PNG, ~15 KB each, so **1.8 MB**.
    ///
    /// The bytes are generated rather than `Data(repeating: 0xFF)`: that
    /// pattern base64-encodes to nothing but `/`, and Foundation escapes
    /// every `/` as `\/`, so a uniform payload would measure the escaping
    /// worst case (2×) instead of the real thing (~2%).
    func testTheFrameStaysSmall() throws {
        let count = 113
        let perIcon = 15_000                      // measured 128 px PNG
        var seed: UInt8 = 0x2A
        func payload() -> Data {
            (0..<perIcon).map { _ in
                seed = seed &* 31 &+ 17
                return seed
            }.withUnsafeBufferPointer { Data($0) }
        }
        let apps = (0..<count).map { i in
            IBInstalledApp(id: "com.example.app\(i)", name: "Example \(i)",
                           iconPNG: payload())
        }
        let size = try IBWire.encode(installedApps: IBInstalledApps(apps: apps)).count
        XCTAssertLessThan(size, (count * perIcon * 4 / 3) + 100_000,
                          "launcher frame is \(size / 1_000_000) MB")
    }
}
