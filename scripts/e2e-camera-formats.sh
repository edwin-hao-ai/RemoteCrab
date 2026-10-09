#!/usr/bin/env bash
#
# Asserts the RemoteCrab virtual camera advertises 4K (3840x2160).
#
# The camera extension offers [1080p, 4K]; a client (Zoom / QuickTime / OBS)
# picks one and the host fills that size. This probe enumerates the device's
# formats — no camera TCC is needed for enumeration, so it runs from a plain
# CLI. It FAILS until the extension has been re-registered + approved
# (System Settings → General → Login Items & Extensions → Camera Extensions),
# which is a manual step after any extension change.
set -uo pipefail

SRC="$(mktemp -d)/probe.swift"
BIN="$(mktemp -d)/probe"
cat > "$SRC" <<'SWIFT'
import AVFoundation
import CoreMedia

let target = "3B7B09B4-2E2A-4C6B-9C0E-1B0E6B0D6A01"
guard let device = AVCaptureDevice.devices(for: .video).first(where: { $0.uniqueID == target }) else {
    print("✗ RemoteCrab Camera not found — is the extension activated?")
    exit(2)
}
var found4K = false
var found1080 = false
for f in device.formats {
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    print("  format \(d.width)x\(d.height)")
    if d.width == 3840 && d.height == 2160 { found4K = true }
    if d.width == 1920 && d.height == 1080 { found1080 = true }
}
if found4K {
    print("✓ 4K (3840x2160) advertised (1080p=\(found1080))")
    exit(0)
}
print("✗ 4K not advertised — extension re-register/approval pending?")
exit(1)
SWIFT

swiftc -O -o "$BIN" "$SRC" -framework AVFoundation -framework CoreMedia 2>/dev/null || {
    echo "✗ could not build the probe"; exit 3
}
echo "== RemoteCrab virtual-camera formats =="
"$BIN"
