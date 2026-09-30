import XCTest

@testable import RemoteCrabCore

/// The wire contract between the Windows receiver and the iPhone.
///
/// Every other test in this repository checks **one half**: the Swift tests
/// check that Swift encodes and decodes `IBNotification`, and the Rust tests
/// check that Rust does the same. Neither can catch the two halves drifting
/// apart — a field renamed on one side, a status value spelled differently, a
/// `#[serde(rename_all)]` forgotten — because each side would keep passing its
/// own round trip perfectly while the product stopped working.
///
/// The only way to catch that is to hand one side's actual bytes to the other.
/// The bytes below were produced by `cargo run -p rc-protocol
/// --example contract_gen`, i.e. by the real Rust encoder, not by hand.
///
/// ## Regenerating the fixtures after a change
///
/// ```sh
/// cd windows
/// cargo run -p rc-protocol --example contract_gen
/// ```
///
/// It prints one JSON object per line, in the order the constants above appear.
/// Paste them in. If a paste makes the suite fail, the two halves genuinely
/// disagree — that is the entire point of this file, and it is the only place
/// in the repository that would notice.
///
/// `contract_gen` is an `example`, so it is not built by `cargo build` and does
/// not reach a release binary.
final class WindowsWireContractTests: XCTestCase {

    // MARK: - 0x22 notification relay (Windows → iPhone)

    /// What `rc_protocol::Notification` actually puts on the wire.
    private static let notificationJSON = "{\"app\":\"Slack\",\"title\":\"Build finished\",\"subtitle\":\"#42\",\"body\":\"12 tests passed\",\"windowTitle\":\"CI\"}"

    func test_rust_encoded_notification_decodes() throws {
        let data = Data(Self.notificationJSON.utf8)
        let n = try JSONDecoder().decode(IBNotification.self, from: data)

        XCTAssertEqual(n.app, "Slack")
        XCTAssertEqual(n.title, "Build finished")
        XCTAssertEqual(n.subtitle, "#42")
        XCTAssertEqual(n.body, "12 tests passed")
        XCTAssertEqual(n.windowTitle, "CI")
    }

    /// A Windows receiver with no screen permission cannot read the window
    /// title, so it omits the key. The phone must still decode the banner — the
    /// whole point of the relay is the text, and losing all of it because an
    /// optional field was missing would be a bad trade.
    ///
    /// The bytes are Rust's `Notification::default()`, which skips the key.
    func test_notification_without_a_window_title_still_decodes() throws {
        let data = Data("{\"app\":\"\",\"title\":\"\",\"subtitle\":\"\",\"body\":\"\"}".utf8)
        let n = try JSONDecoder().decode(IBNotification.self, from: data)
        XCTAssertNil(n.windowTitle)
    }

    /// The key is `windowTitle`, not `window_title`. A snake_case key decodes
    /// to nil on this side and the tap-to-activate feature silently stops
    /// working, with nothing in any log.
    func test_the_window_title_key_is_camel_case() throws {
        let snake = Data("{\"app\":\"a\",\"title\":\"t\",\"subtitle\":\"s\",\"body\":\"b\",\"window_title\":\"w\"}".utf8)
        let n = try JSONDecoder().decode(IBNotification.self, from: snake)
        XCTAssertNil(n.windowTitle, "a snake_case key must not be accepted as the window title")
    }

    // MARK: - 0x23 command result (receiver → iPhone)

    /// What `rc_protocol::CommandResult` actually puts on the wire.
    private static let commandResultJSON = "{\"requestId\":\"a1\",\"status\":\"appNotRunning\",\"detail\":\"目标应用没有运行\"}"

    func test_rust_encoded_command_result_decodes() throws {
        let data = Data(Self.commandResultJSON.utf8)
        let r = try JSONDecoder().decode(IBCommandResult.self, from: data)

        XCTAssertEqual(r.requestId, "a1")
        XCTAssertEqual(r.status, .appNotRunning)
        XCTAssertEqual(r.detail, "目标应用没有运行")
    }

    /// Every status the Rust enum can emit has to exist here. Rust's
    /// `CommandStatus` and Swift's `IBCommandResult.Status` are separate
    /// declarations of the same contract, and adding a case to one without the
    /// other is precisely the drift this file exists to catch — a status Rust
    /// sends that the phone cannot name becomes a generic failure message.
    func test_every_rust_status_value_exists_on_this_side() throws {
        // Written out by hand rather than generated, because the point is that
        // a human looks at it when the Rust side changes.
        let rustValues = ["ok", "appNotRunning", "noPermission", "noWindow", "failed"]
        for value in rustValues {
            let json = "{\"requestId\":\"a\",\"status\":\"" + value + "\",\"detail\":null}"
            let decoded = try JSONDecoder().decode(IBCommandResult.self, from: Data(json.utf8))
            XCTAssertNotNil(decoded.requestId, "\(value) should decode")
        }
    }

    /// `detail` is optional on both sides: a sender that has nothing to add
    /// omits it, and a phone that requires it would show a failure with no
    /// explanation.
    func test_a_command_result_without_detail_still_decodes() throws {
        let json = "{\"requestId\":\"a1\",\"status\":\"ok\"}"
        let r = try JSONDecoder().decode(IBCommandResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .ok)
        XCTAssertNil(r.detail)
    }

    /// The frame kind. Both sides hard-code `0x22` and `0x23`; if either moves,
    /// the other still "recognises the kind" and drops the frame — the failure
    /// mode this file's header describes.
    func test_the_frame_kinds_are_still_these_numbers() {
        // The kind's own raw value, not a literal repeated here: a test that
        // hard-codes the constant it is checking cannot catch it moving.
        XCTAssertEqual(IBWire.Kind.notification.rawValue, 0x22)
        XCTAssertEqual(IBWire.Kind.commandResult.rawValue, 0x23)
    }

    /// And the Rust side, read out of the workspace rather than repeated.
    ///
    /// This is the check that makes the file a *contract* test rather than two
    /// unconnected round trips: if someone renumbers a kind in `wire.rs`, CI
    /// fails here instead of the two ends silently disagreeing on a machine.
    func test_the_rust_side_uses_the_same_kind_numbers() throws {
        let wire = try XCTUnwrap(Self.rustWireSource(), "crates/rc-protocol/src/wire.rs not found")
        XCTAssertTrue(
            wire.contains("Notification = 0x22"),
            "the Rust kind for notifications is no longer 0x22"
        )
        XCTAssertTrue(
            wire.contains("CommandResult = 0x23"),
            "the Rust kind for command results is no longer 0x23"
        )
    }

    /// The Rust wire source.
    ///
    /// Found by walking up from the *working directory* looking for the
    /// `windows/` sibling, because `#filePath` in a compiled test bundle points
    /// inside `.build`, where walking up never reaches the checkout — which is
    /// why the first version of this test always failed to find the file.
    private static func rustWireSource() -> String? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("windows/crates/rc-protocol/src/wire.rs")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try? String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
