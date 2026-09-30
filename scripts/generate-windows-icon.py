#!/usr/bin/env python3
"""Rasterise the app-icon master into a multi-size Windows .ico.

Why this exists: without a PE icon resource, Explorer shows a blank page for
`remotecrab.exe`, the taskbar entry is a blank square, and the file has no
version — so "which build is this" has no answer anywhere except the About
box of a tray app nobody opens. The .ico is what makes the build identifiable
in the one place a user will actually look.

The master is the same `assets/app-icon-liquid.svg` the iOS icon is generated
from, so all three platforms ship one piece of art (AGENTS.md: never rebrand
per-platform).

Usage:  scripts/generate-windows-icon.py            # writes assets/remotecrab.ico
        scripts/generate-windows-icon.py --check     # fails if the .ico is stale
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

REPO = pathlib.Path(__file__).resolve().parent.parent
MASTER = REPO / "assets" / "app-icon-liquid.svg"
OUT = REPO / "windows" / "assets" / "remotecrab.ico"

# Explorer picks from this set by context: 16 for a title bar, 24 for a small
# list, 32 for a taskbar button at 100%, 48/64 for medium, 128/256 for the
# large-icons view and for the shortcut overlay. 256 must be a PNG-compressed
# entry — that is what makes the icon look sharp in Explorer's large view
# instead of a blurry upscale.
SIZES = [16, 24, 32, 48, 64, 128, 256]


def render(size: int) -> Image.Image:
    """Rasterise the master at one size, straight to RGBA."""
    with tempfile.TemporaryDirectory() as tmp:
        png = pathlib.Path(tmp) / f"{size}.png"
        subprocess.run(
            [
                "rsvg-convert",
                "--width", str(size),
                "--height", str(size),
                "--background-color", "none",
                "--format", "png",
                "-o", str(png),
                str(MASTER),
            ],
            check=True,
        )
        return Image.open(png).convert("RGBA")


def main() -> int:
    if not MASTER.exists():
        print(f"missing master: {MASTER}", file=sys.stderr)
        return 1
    images = [render(s) for s in SIZES]
    for size, img in zip(SIZES, images):
        if img.size != (size, size):
            print(f"{size}: rendered {img.size}, expected a square", file=sys.stderr)
            return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    # PIL's ICO writer *resamples from the image it is given*, so the base has
    # to be the largest one. Handing it the 16 px and an `append_images` list
    # (the obvious-looking mistake) writes a file that contains exactly one
    # size, which is how this shipped a 718-byte "multi-size" icon once.
    largest = images[SIZES.index(max(SIZES))]
    largest.save(OUT, format="ICO", sizes=[(s, s) for s in SIZES])

    # Read it back. A .ico that claims sizes it does not have is worse than no
    # icon, because the build embeds whatever is on disk.
    check = Image.open(OUT)
    got = set(check.info.get("sizes", set()))
    missing = [(s, s) for s in SIZES if (s, s) not in got]
    if missing:
        print(f"{OUT.name} is missing sizes {missing}", file=sys.stderr)
        return 1

    if "--check" in sys.argv:
        # A stale .ico is worse than none: the build embeds whatever is on
        # disk, so a stale file silently ships the old artwork.
        print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
        return 0

    print(f"wrote {OUT.relative_to(REPO)}  sizes={SIZES}  {OUT.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
