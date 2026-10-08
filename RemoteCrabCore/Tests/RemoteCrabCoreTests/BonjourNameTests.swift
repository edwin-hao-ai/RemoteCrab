import XCTest
@testable import RemoteCrabCore

/// A Bonjour instance-name collision gets a `" (2)"` suffix; the receiver's
/// identity map is keyed by the base name, so the suffix must be stripped or a
/// phone-initiated phone is treated as a legacy one.
final class BonjourNameTests: XCTestCase {

    func testCollisionSuffixIsStripped() {
        XCTAssertEqual(BonjourName.base("RemoteCrab — Edwin's iPhone (2)"),
                       "RemoteCrab — Edwin's iPhone")
        XCTAssertEqual(BonjourName.base("RemoteCrab — Edwin's iPhone (10)"),
                       "RemoteCrab — Edwin's iPhone")
    }

    func testNameWithoutSuffixIsUnchanged() {
        XCTAssertEqual(BonjourName.base("RemoteCrab — Edwin's iPhone"),
                       "RemoteCrab — Edwin's iPhone")
    }

    func testNonNumericParenthesesAreNotStripped() {
        XCTAssertEqual(BonjourName.base("RemoteCrab — iPhone (Pro)"),
                       "RemoteCrab — iPhone (Pro)")
    }

    func testParenthesesWithoutPrecedingSpaceAreNotStripped() {
        XCTAssertEqual(BonjourName.base("RemoteCrab — iPhone(2)"),
                       "RemoteCrab — iPhone(2)")
    }

    func testOnlyTheTrailingSuffixIsStripped() {
        XCTAssertEqual(BonjourName.base("RemoteCrab — iPhone (2) (3)"),
                       "RemoteCrab — iPhone (2)")
    }

    func testEmptyParenthesesAreNotStripped() {
        XCTAssertEqual(BonjourName.base("iPhone ()"), "iPhone ()")
    }
}
