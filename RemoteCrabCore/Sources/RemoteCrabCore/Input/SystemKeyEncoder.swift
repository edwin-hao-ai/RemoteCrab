/// Encodes the `data1` field of an NX system-defined (media key) event
/// the way WindowServer expects it (IOKit `ev_keymap.h`):
/// `data1 = (key << 16) | flags`, flags = 0xA00 key-down / 0xB00 key-up.
///
/// Pure so the wire-to-CGEvent path is unit-testable — the V1.1 bug this
/// pins down was a double-shifted flags byte that WindowServer dropped
/// silently (volume/mute buttons did nothing on device).
public enum SystemKeyEncoder {
    public static func data1(key: Int32, down: Bool) -> Int {
        (Int(key) << 16) | (down ? 0xA00 : 0xB00)
    }
}
