import XCTest
@testable import RemoteCrabCore

/// The ⊞ key. `keymap.rs` already turns macOS keycode 55 (kVK_Command)
/// into `LWIN`, but a *chord* needs the modifier bit too — and the
/// original wire mask only defined 1/2/4/8, with `command` collapsing
/// into Ctrl on Windows. So ⊞E / ⊞R / ⊞D / ⊞L were unreachable.
final class MetaModifierTests: XCTestCase {

    func testMetaBitIsSixteen() {
        XCTAssertEqual(TouchEvent.Modifier.meta.rawValue, 16)
    }

    /// 旧数据不含 16 这一位，解码必须仍然成功（规则 2）。
    func testMetaBitRoundTripsThroughTheWire() throws {
        let event = TouchEvent(phase: .move, dx: 1,
                               modifiers: TouchEvent.Modifier.meta.rawValue)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(TouchEvent.self, from: data).modifiers, 16)
    }

    /// meta 不得与既有四位重叠——重叠会让 Windows 端静默把 ⊞ 当成 Ctrl。
    func testMetaDoesNotOverlapExistingBits() {
        let existing: [TouchEvent.Modifier] = [.shift, .control, .option, .command]
        for m in existing {
            XCTAssertEqual(m.rawValue & TouchEvent.Modifier.meta.rawValue, 0, "\(m)")
        }
    }

    /// ⊞ 与 ⌘ 可以同时按住（⊞⇧… 这类组合），所以两位必须能共存。
    func testMetaCoexistsWithEveryOtherBit() {
        var mask = TouchEvent.Modifier.meta.rawValue
        for m in [TouchEvent.Modifier.shift, .control, .option, .command] {
            mask |= m.rawValue
        }
        XCTAssertEqual(mask, 16 | 1 | 2 | 4 | 8)
    }
}