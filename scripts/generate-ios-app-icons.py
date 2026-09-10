#!/usr/bin/env python3
"""Generate iBridge iOS AppIcon.appiconset PNGs from a 1024x1024 source.

Usage:
    python3 scripts/generate-ios-app-icons.py
    python3 scripts/generate-ios-app-icons.py path/to/source-1024.png

If no source is provided, renders the master SVG
(`assets/app-icon-liquid.svg` — the Liquid Glass "monitor buddy"
mascot) to `assets/source-1024-ios.png` via rsvg-convert, then
generates all the AppIcon sizes into
`iBridgeCapture/Assets.xcassets/AppIcon.appiconset/`.

Design language: a friendly glass monitor character (the "monitor
buddy") with glowing cyan eyes and a signal antenna, rendered as
stacked Liquid Glass layers over a deep navy background with
refracted ambient light blobs. The SVG master is hand-drawn and
fully original — see docs/superpowers/specs/2026-09-10-liquid-glass-icon-design.md.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None  # type: ignore


ROOT = Path(__file__).resolve().parent.parent
ASSET_CATALOG = ROOT / "iBridgeCapture" / "Assets.xcassets" / "AppIcon.appiconset"
MARKETING_PATH = ROOT / "screenshots" / "app-store-marketing-icon.png"

DEFAULT_SOURCE = ROOT / "assets" / "source-1024-ios.png"
MASTER_SVG = ROOT / "assets" / "app-icon-liquid.svg"

ICON_SIZES = [
    ("AppIcon-iphone67-20@2x.png",  "20x20",  "2x"),
    ("AppIcon-iphone67-20@3x.png",  "20x20",  "3x"),
    ("AppIcon-iphone67-29@2x.png",  "29x29",  "2x"),
    ("AppIcon-iphone67-29@3x.png",  "29x29",  "3x"),
    ("AppIcon-iphone67-40@2x.png",  "40x40",  "2x"),
    ("AppIcon-iphone67-40@3x.png",  "40x40",  "3x"),
    ("AppIcon-iphone67-60@2x.png",  "60x60",  "2x"),
    ("AppIcon-iphone67-60@3x.png",  "60x60",  "3x"),
    ("AppIcon-ipad129-20@1x.png",   "20x20",  "1x"),
    ("AppIcon-ipad129-29@1x.png",   "29x29",  "1x"),
    ("AppIcon-ipad129-40@1x.png",   "40x40",  "1x"),
    ("AppIcon-ipad129-76@2x.png",   "76x76",  "2x"),
    ("AppIcon-ipad129-83.5@2x.png", "83.5x83.5", "2x"),
    ("AppIcon-marketing-1024.png",  "1024x1024", "1x"),
]


def parse_size(size_str: str) -> tuple[float, float]:
    w, h = size_str.split("x")
    return float(w), float(h)


def render_default_source(target: Path) -> Path:
    """Render the Liquid Glass "monitor buddy" master SVG to 1024x1024.

    Rasterizes `assets/app-icon-liquid.svg` at 2048px with
    rsvg-convert, then Lanczos-downscales to 1024px for smooth
    anti-aliasing.
    """
    if Image is None:
        print("PIL is required to render the default icon. pip install pillow",
              file=sys.stderr)
        sys.exit(1)
    if not MASTER_SVG.exists():
        print(f"❌ Master SVG not found: {MASTER_SVG}", file=sys.stderr)
        sys.exit(1)
    if shutil.which("rsvg-convert") is None:
        print("rsvg-convert is required. brew install librsvg",
              file=sys.stderr)
        sys.exit(1)

    target.parent.mkdir(parents=True, exist_ok=True)
    hi_res = target.with_suffix(".2048.png")
    subprocess.run(
        ["rsvg-convert", "-w", "2048", "-h", "2048",
         str(MASTER_SVG), "-o", str(hi_res)],
        check=True)
    Image.open(hi_res).resize((1024, 1024), Image.LANCZOS) \
        .convert("RGB").save(target, "PNG")
    hi_res.unlink()
    print(f"✓ Rendered {MASTER_SVG.name} → {target}")
    return target


def generate_appicon_set(source: Path) -> int:
    if Image is None:
        print("PIL is required to generate icons. pip install pillow",
              file=sys.stderr)
        return 1

    if not source.exists():
        print(f"❌ Source icon not found: {source}", file=sys.stderr)
        return 1

    src = Image.open(source).convert("RGB")
    if src.size != (1024, 1024):
        print(f"⚠ Source is {src.size}, resizing to 1024x1024 first.",
              file=sys.stderr)
        src = src.resize((1024, 1024), Image.LANCZOS)

    contents_path = ASSET_CATALOG / "Contents.json"
    if not contents_path.exists():
        print(f"❌ {contents_path} not found — run 'xcodegen generate' first.",
              file=sys.stderr)
        return 1

    with open(contents_path) as f:
        contents = json.load(f)

    ASSET_CATALOG.mkdir(parents=True, exist_ok=True)

    for image in contents.get("images", []):
        filename = image.get("filename")
        size = image.get("size")
        scale = image.get("scale")
        if not (filename and size and scale):
            continue
        w, h = parse_size(size)
        scale_val = int(scale.replace("x", ""))
        pixel = int(max(w, h) * scale_val)
        out = src.resize((pixel, pixel), Image.LANCZOS)
        out.save(ASSET_CATALOG / filename, "PNG")
        print(f"  {filename:42s} → {pixel}x{pixel}")

    if MARKETING_PATH.parent.exists():
        src.save(MARKETING_PATH, "PNG")
        print(f"  marketing icon → {MARKETING_PATH}")

    print(f"✓ Wrote {len(contents.get('images', []))} icons to {ASSET_CATALOG}")
    return 0


def main() -> int:
    source_arg = Path(sys.argv[1]) if len(sys.argv) > 1 else None

    if source_arg is None:
        if Image is None:
            print("PIL is required to render the default icon. pip install pillow",
                  file=sys.stderr)
            return 1
        DEFAULT_SOURCE.parent.mkdir(parents=True, exist_ok=True)
        source = render_default_source(DEFAULT_SOURCE)
    else:
        source = source_arg

    return generate_appicon_set(source)


if __name__ == "__main__":
    sys.exit(main())