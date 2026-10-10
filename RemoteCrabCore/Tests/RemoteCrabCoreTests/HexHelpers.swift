import Foundation

/// Test-only hex helpers (shared by the transport-vector tests).
extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString: String) {
        var bytes = [UInt8]()
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            if let b = UInt8(hexString[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        self = Data(bytes)
    }
}
