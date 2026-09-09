#!/usr/bin/env python3
"""Generate iBridge iOS AppIcon.appiconset PNGs from a 1024x1024 source.

Usage:
    python3 scripts/generate-ios-app-icons.py
    python3 scripts/generate-ios-app-icons.py path/to/source-1024.png

If no source is provided, generates a default iBridge brand icon
(blue gradient with stylized "iB" mark + wifi waves) and writes it
to `assets/source-1024-ios.png`, then generates all the AppIcon
sizes into `iBridgeCapture/Assets.xcassets/AppIcon.appiconset/`.

The generated PNG sizes match Apple's AppIcon spec for iOS 17+:
    iphone67, iphone65, iphone55, ipad129
    + marketing 1024x1024.

This is a generic script — it works on any 1024x1024 source PNG.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# Image generation imports only happen when no source is provided.
# This keeps the script usable for the common "regenerate from my
# source-1024-ios.png" case without requiring PIL upfront.
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = ImageDraw = ImageFont = None  # type: ignore


ROOT = Path(__file__).resolve().parent.parent

# Generated icon path inside the iOS Xcode project
ASSET_CATALOG = ROOT / "iBridgeCapture" / "Assets.xcassets" / "AppIcon.appiconset"
MARKETING_PATH = ROOT / "screenshots" / "app-store-marketing-icon.png"

# If user provides a custom source, that wins.
DEFAULT_SOURCE = ROOT / "assets" / "source-1024-ios.png"

# Apple's iOS 17+ AppIcon spec. Each tuple: (filename, size-string, scale)
# For "size 60x60 scale 2x" we generate 120x120 PNG.
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
    """Render the iBridge brand mark as a 1024x1024 PNG and write it to
    `target`. Returns the written path.

    Design principles (per Apple HIG + best-of-class minimalist icons):
      • ONE focal element — the iPhone silhouette
      • NO text — the product *is* the iPhone-to-Mac connection
      • WiFi waves as supporting visual rhythm (NOT competing)
      • Generous negative space (gradient breathes)
      • Rich Apple-Native gradient
      • Soft drop shadow for depth
    """
    if Image is None:
        print("PIL is required to render the default icon. pip install pillow",
              file=sys.stderr)
        sys.exit(1)
    target.parent.mkdir(parents=True, exist_ok=True)

    import math

    size = 1024
    img = Image.new("RGB", (size, size), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # ---- Background: deep navy → violet gradient (Apple Native) ----
    for y in range(size):
        t = y / size
        r = int(0x0c + (0x6a - 0x0c) * t)
        g = int(0x12 + (0x16 - 0x12) * t)
        b = int(0x36 + (0x9e - 0x36) * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b))

    # ---- Diagonal accent glow top-left → bottom-right ----
    # This adds depth without competing with the iPhone.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    cx_g, cy_g = size * 0.32, size * 0.4
    for r in range(60, 700, 4):
        a = int(35 * (1 - (r - 60) / 640))
        if a <= 0:
            break
        glow_draw.ellipse(
            [cx_g - r, cy_g - r, cx_g + r, cy_g + r],
            outline=(120, 80, 220, a), width=2)
    img.paste(glow, (0, 0), glow)

    # ============================================================
    # FOCAL: stylized iPhone silhouette, centered
    # ============================================================
    # iPhone body proportions match a real iPhone (about 9:19.5 ratio).
    phone_w = 340
    phone_h = 680
    phone_x = (size - phone_w) / 2
    phone_y = (size - phone_h) / 2
    corner = 60  # generous rounded corner (matches iPhone design)

    # Drop shadow behind the phone
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        [phone_x + 12, phone_y + 36, phone_x + phone_w + 12, phone_y + phone_h + 36],
        radius=corner, fill=(0, 0, 0, 110))
    img.paste(shadow, (0, 0), shadow)

    # ---- The iPhone SCREEN: shows the iBridge gradient through,
    # giving a sense that the iBridge app is "running on" the iPhone.
    # We don't draw a body; the iPhone is a thin bezel frame around
    # a tinted view of the background.

    # A single soft elliptical highlight at the top — suggests the
    # screen is "on" without overdoing it. (Avoids the hatch-mark
    # look of multiple concentric rings.)
    inner = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner_draw = ImageDraw.Draw(inner)
    inner_draw.ellipse(
        [phone_x + phone_w / 2 - 240,
         phone_y - 180,
         phone_x + phone_w / 2 + 240,
         phone_y + 140],
        fill=(255, 255, 255, 22))
    img.paste(inner, (0, 0), inner)

    # ---- iPhone bezel frame: a clean white outline that contains
    # the gradient behind the screen. The bezel is THICKER (10pt)
    # so the phone reads clearly at 60×60.
    bezel_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bezel_draw = ImageDraw.Draw(bezel_layer)
    # Outer white bezel — the "case" the user sees.
    bezel_draw.rounded_rectangle(
        [phone_x, phone_y, phone_x + phone_w, phone_y + phone_h],
        radius=corner, outline=(255, 255, 255, 245), width=10)
    img.paste(bezel_layer, (0, 0), bezel_layer)

    # Dynamic Island (centered, near the top)
    island_w = 130
    island_h = 34
    island_x = phone_x + (phone_w - island_w) / 2
    island_y = phone_y + 20
    island_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    island_draw = ImageDraw.Draw(island_layer)
    island_draw.rounded_rectangle(
        [island_x, island_y, island_x + island_w, island_y + island_h],
        radius=island_h / 2, fill=(8, 8, 14, 255))
    # Tiny camera dot
    cam_r = 4
    cam_cx = island_x + island_w - 14
    cam_cy = island_y + island_h / 2
    island_draw.ellipse(
        [cam_cx - cam_r, cam_cy - cam_r, cam_cx + cam_r, cam_cy + cam_r],
        fill=(40, 50, 80, 255))
    img.paste(island_layer, (0, 0), island_layer)

    # Home indicator (bottom bar)
    home_w = 130
    home_h = 6
    home_x = phone_x + (phone_w - home_w) / 2
    home_y = phone_y + phone_h - 18
    home_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    home_draw = ImageDraw.Draw(home_layer)
    home_draw.rounded_rectangle(
        [home_x, home_y, home_x + home_w, home_y + home_h],
        radius=home_h / 2, fill=(255, 255, 255, 220))
    img.paste(home_layer, (0, 0), home_layer)

    # ============================================================
    # SUPPORTING: WiFi waves emanating from BOTH sides of the iPhone.
    # This is the "iPhone ↔ Mac" bridge visual.
    # ============================================================
    # Right-side waves (emanating from the right edge of the iPhone).
    wave_cx_r = phone_x + phone_w - 6
    wave_cy = phone_y + phone_h * 0.5
    wave_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    wave_draw = ImageDraw.Draw(wave_layer)
    for r, alpha, width in [
        (130, 220, 14),
        (210, 170, 12),
        (290, 120, 10),
        (370, 75, 8),
    ]:
        for theta_deg in range(-55, 56, 3):
            theta = math.radians(theta_deg)
            x0 = wave_cx_r + int(r * 0.94 * math.cos(theta))
            y0 = wave_cy + int(r * 0.94 * math.sin(theta))
            x1 = wave_cx_r + int(r * 1.04 * math.cos(theta))
            y1 = wave_cy + int(r * 1.04 * math.sin(theta))
            if not (8 < x1 < size - 8 and 8 < y1 < size - 8):
                continue
            wave_draw.line(
                [(x0, y0), (x1, y1)],
                fill=(180, 200, 255, alpha), width=width)
    img.paste(wave_layer, (0, 0), wave_layer)

    # Left-side waves (mirror) — same 4 rings, mirrored angle.
    wave_cx_l = phone_x + 6
    wave_layer_l = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    wave_draw_l = ImageDraw.Draw(wave_layer_l)
    for r, alpha, width in [
        (130, 220, 14),
        (210, 170, 12),
        (290, 120, 10),
        (370, 75, 8),
    ]:
        for theta_deg in range(180 - 55, 180 + 56, 3):
            theta = math.radians(theta_deg)
            x0 = wave_cx_l + int(r * 0.94 * math.cos(theta))
            y0 = wave_cy + int(r * 0.94 * math.sin(theta))
            x1 = wave_cx_l + int(r * 1.04 * math.cos(theta))
            y1 = wave_cy + int(r * 1.04 * math.sin(theta))
            if not (8 < x1 < size - 8 and 8 < y1 < size - 8):
                continue
            wave_draw_l.line(
                [(x0, y0), (x1, y1)],
                fill=(180, 200, 255, alpha), width=width)
    img.paste(wave_layer_l, (0, 0), wave_layer_l)

    img.save(target, "PNG")
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

    # Also write a marketing 1024×1024 to the screenshots folder for
    # press kits, README badges, etc.
    if MARKETING_PATH.parent.exists():
        src.save(MARKETING_PATH, "PNG")
        print(f"  marketing icon → {MARKETING_PATH}")

    print(f"✓ Wrote {len(contents.get('images', []))} icons to {ASSET_CATALOG}")
    return 0


def main() -> int:
    source_arg = Path(sys.argv[1]) if len(sys.argv) > 1 else None

    # If the caller didn't pass a source, generate the default brand
    # icon first, then run the rest of the pipeline on it.
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