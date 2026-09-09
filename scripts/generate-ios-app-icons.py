#!/usr/bin/env python3
"""Generate iBridge iOS AppIcon.appiconset PNGs from a 1024x1024 source.

Usage:
    python3 scripts/generate-ios-app-icons.py
    python3 scripts/generate-ios-app-icons.py path/to/source-1024.png

If no source is provided, generates a default iBridge brand icon and
writes it to `assets/source-1024-ios.png`, then generates all the
AppIcon sizes into `iBridgeCapture/Assets.xcassets/AppIcon.appiconset/`.

Design language: a single ivory iPhone silhouette floating on a deep
Apple-style gradient (navy → violet → warm rose). No text, no wifi
waves, no halos. The mark is solid ivory with a single warm-pink
glow at the top (suggests "screen on / live"). Inspired by the
silhouette-driven icons like TestFlight, Apple Music, Procreate.
"""
from __future__ import annotations

import json
import os
import random
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    Image = ImageDraw = None  # type: ignore


ROOT = Path(__file__).resolve().parent.parent
ASSET_CATALOG = ROOT / "iBridgeCapture" / "Assets.xcassets" / "AppIcon.appiconset"
MARKETING_PATH = ROOT / "screenshots" / "app-store-marketing-icon.png"

DEFAULT_SOURCE = ROOT / "assets" / "source-1024-ios.png"

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


def lerp(a: int, b: int, t: float) -> int:
    return int(a + (b - a) * t)


def render_default_source(target: Path) -> Path:
    """Render the iBridge brand mark as a 1024x1024 PNG.

    Composition:
      • Deep 3-stop Apple-style gradient (navy → violet → warm rose)
        with subtle grain for photographic depth
      • A single ivory iPhone silhouette as the focal mark
        (warm-ivory gradient body, dark Dynamic Island, home indicator)
      • One subtle warm-pink glow at the top of the mark
        (suggests "screen is on / live")
      • No text, no WiFi waves, no halos — one clean mark

    The result is meant to feel like an Apple Design Award entry,
    not a tech diagram. Single object on rich gradient.
    """
    if Image is None:
        print("PIL is required to render the default icon. pip install pillow",
              file=sys.stderr)
        sys.exit(1)
    target.parent.mkdir(parents=True, exist_ok=True)

    size = 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # ============================================================
    # BACKGROUND: 3-stop gradient
    # ============================================================
    # Top:    deep navy  #0a0e2a
    # Mid:    violet    #3d1660
    # Bot:    warm rose  #9c2864
    for y in range(size):
        t = y / size
        if t < 0.55:
            u = t / 0.55
            r = lerp(0x0a, 0x3d, u)
            g = lerp(0x0e, 0x16, u)
            b = lerp(0x2a, 0x60, u)
        else:
            u = (t - 0.55) / 0.45
            r = lerp(0x3d, 0x9c, u)
            g = lerp(0x16, 0x28, u)
            b = lerp(0x60, 0x64, u)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # ============================================================
    # Subtle grain (photographic depth) — very faint
    # ============================================================
    random.seed(42)
    for _ in range(size * size // 200):
        x = random.randint(0, size - 1)
        y = random.randint(0, size - 1)
        a = random.randint(0, 14)
        c = random.randint(220, 255)
        draw.point((x, y), fill=(c, c, c, a))

    # ============================================================
    # THE iPHONE MARK — single ivory silhouette
    # ============================================================
    phone_w = 360
    phone_h = 720
    phone_x = (size - phone_w) // 2
    phone_y = (size - phone_h) // 2
    corner = 70

    # Soft drop shadow
    for r in range(20, 80, 8):
        t = (r - 20) / 60
        a = int(70 * (1 - t))
        if a <= 0:
            break
        draw.rounded_rectangle(
            [phone_x + 14, phone_y + 28,
             phone_x + phone_w + 14, phone_y + phone_h + 28],
            radius=corner + r // 2, outline=(0, 0, 0, a), width=4)

    # The iPhone body — a warm ivory gradient
    # (Pure RGB values; alpha is implicitly 255 for opaque fills)
    for y in range(phone_h):
        t = y / phone_h
        # Top: warmer (toward pink glow), bottom: cooler
        r = lerp(0xff, 0xee, t)
        g = lerp(0xf8, 0xe2, t)
        b = lerp(0xf2, 0xea, t)
        draw.line(
            [(phone_x, phone_y + y),
             (phone_x + phone_w, phone_y + y)],
            fill=(r, g, b, 255))

    # ============================================================
    # DYNAMIC ISLAND (small black capsule near the top)
    # ============================================================
    island_w = 130
    island_h = 32
    island_x = phone_x + (phone_w - island_w) // 2
    island_y = phone_y + 22
    draw.rounded_rectangle(
        [island_x, island_y, island_x + island_w, island_y + island_h],
        radius=island_h // 2, fill=(10, 10, 18, 255))
    # Camera lens — subtle dark dot
    cam_r = 4
    cam_cx = island_x + island_w - 16
    cam_cy = island_y + island_h // 2
    draw.ellipse(
        [cam_cx - cam_r, cam_cy - cam_r, cam_cx + cam_r, cam_cy + cam_r],
        fill=(60, 70, 100, 255))

    # ============================================================
    # HOME INDICATOR (subtle bar at the bottom)
    # ============================================================
    home_w = 120
    home_h = 5
    home_x = phone_x + (phone_w - home_w) // 2
    home_y = phone_y + phone_h - 16
    draw.rounded_rectangle(
        [home_x, home_y, home_x + home_w, home_y + home_h],
        radius=home_h // 2, fill=(110, 90, 110, 200))

    # ============================================================
    # WARM-PINK GLOW on the top of the iPhone (suggests "live")
    # ============================================================
    # Use a separate RGBA layer for the glow, then paste with
    # a mask so it's clipped to the iPhone body shape.
    glow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gldraw = ImageDraw.Draw(glow_layer)
    for r in range(0, 200, 6):
        t = r / 200
        a = int(120 * (1 - t * t))
        if a <= 0:
            break
        gldraw.ellipse(
            [phone_x + phone_w // 2 - r * 1.5,
             phone_y - r * 0.4,
             phone_x + phone_w // 2 + r * 1.5,
             phone_y + r * 0.8],
            outline=(255, 130, 170, a), width=4)

    # Mask the glow to the iPhone body
    glow_mask = Image.new("L", (size, size), 0)
    gmdraw = ImageDraw.Draw(glow_mask)
    gmdraw.rounded_rectangle(
        [phone_x, phone_y, phone_x + phone_w, phone_y + phone_h],
        radius=corner, fill=255)

    masked_glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    masked_glow.paste(glow_layer, (0, 0), glow_mask)
    img.alpha_composite(masked_glow)

    # ============================================================
    # Subtle vignette for depth
    # ============================================================
    vignette = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    vdraw = ImageDraw.Draw(vignette)
    for r in range(size, size // 2, -4):
        t = (size - r) / (size // 2)
        a = int(120 * t)
        if a <= 0:
            break
        vdraw.ellipse(
            [size // 2 - r, size // 2 - r, size // 2 + r, size // 2 + r],
            outline=(0, 0, 0, a), width=4)
    img.alpha_composite(vignette)

    # Convert to RGB for saving (PIL PNG writer likes RGB)
    rgb = Image.new("RGB", (size, size), (0, 0, 0))
    rgb.paste(img, (0, 0), img)
    rgb.save(target, "PNG")
    print(f"✓ Wrote default brand icon → {target}")
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