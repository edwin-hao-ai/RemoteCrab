import XCTest
@testable import RemoteCrabCore

final class SystemKeyEncoderTests: XCTestCase {

    func testVolumeUpDownEncoding() {
        // NX_KEYTYPE_SOUND_UP = 0: flags live in the low 16 bits.
        XCTAssertEqual(SystemKeyEncoder.data1(key: 0, down: true), 0xA00)
        XCTAssertEqual(SystemKeyEncoder.data1(key: 0, down: false), 0xB00)
    }

    func testKeyOccupiesHighBits() {
        // NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_MUTE = 7.
        XCTAssertEqual(SystemKeyEncoder.data1(key: 16, down: true), 0x100A00)
        XCTAssertEqual(SystemKeyEncoder.data1(key: 7, down: false), 0x70B00)
    }

    func testFlagsDoNotBleedIntoKeyField() {
        // Regression guard for the V1.1 double-shift bug: (flags << 8)
        // produced 0xA0000, which WindowServer decoded as "key 10, no
        // state" and dropped — media keys silently did nothing on device.
        let data1 = SystemKeyEncoder.data1(key: 0, down: true)
        XCTAssertEqual((data1 >> 16) & 0xFFFF, 0)
        XCTAssertEqual(data1 & 0xFF00, 0xA00)
    }
}
