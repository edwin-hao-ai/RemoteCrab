#!/usr/bin/env python3
"""Compose Kickstarter narrative images from real device screenshots.

Every input is a REAL capture from build/asc-raw/ (device or Mac window), never
a design mockup. The point of this script is that a backer scrolling the story
sees the actual product, with one sentence of context over each shot.

Usage:  python3 scripts/kickstarter-graphics.py <outdir>
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "build", "asc-raw")

# The product's own palette. Deep indigo -> violet, matching the app's
# Liquid Glass surfaces so the page and the product look like one thing.
BG_A = (18, 14, 38)
BG_B = (58, 30, 96)
BG_C = (124, 58, 168)
ACCENT = (10, 132, 255)
INK = (255, 255, 255)
INK_DIM = (196, 190, 216)

FONT_DISPLAY = "/System/Library/Fonts/SFNS.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(path, size):
    return ImageFont.truetype(path, size)


def gradient(size, c_a=BG_A, c_b=BG_B, c_c=BG_C, diagonal=True):
    """Three-stop diagonal gradient, rendered small then upscaled.

    Upscaling is what keeps the banding out of a 1280px gradient; PIL's
    linear interpolation bands badly on wide dark ramps.
    """
    w, h = size
    small = Image.new("RGB", (max(2, w // 8), max(2, h // 8)))
    d = ImageDraw.Draw(small)
    sw, sh = small.size
    n = (sw + sh) if diagonal else max(sw, sh)
    for i in range(n * 2):
        t = min(1.0, i / max(1, n))
        if t < 0.5:
            u = t / 0.5
            col = tuple(int(c_a[k] + (c_b[k] - c_a[k]) * u) for k in range(3))
        else:
            u = (t - 0.5) / 0.5
            col = tuple(int(c_b[k] + (c_c[k] - c_b[k]) * u) for k in range(3))
        if diagonal:
            d.line([(i, 0), (0, i)], fill=col)
        else:
            x = int(i / 2) if n == sw else 0
            y = 0 if n == sw else int(i / 2)
            d.line([(x, 0 if n == sw else y), (x, sh if n == sw else y)], fill=col)
    return small.resize(size, Image.LANCZOS)


def add_glow(base, xy, radius, color, strength=0.5):
    """Additive radial bloom — the app's accent blue over the violet ramp.

    Additive rather than screen-blend: screen darkens the black point, which
    on a dark indigo ramp reads as a grey smudge instead of light.
    """
    layer = Image.new("RGB", base.size, (0, 0, 0))
    d = ImageDraw.Draw(layer)
    steps = 30
    for i in range(steps, 0, -1):
        t = i / steps
        r = radius * t
        a = (1 - t) ** 2 * strength
        d.ellipse(
            [xy[0] - r, xy[1] - r, xy[0] + r, xy[1] + r],
            fill=tuple(int(color[k] * a) for k in range(3)),
        )
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.14))

    px_b, px_l, px_o = base.load(), layer.load(), base.copy().load()
    w, h = base.size
    for y in range(h):
        for x in range(w):
            br, bg, bb = px_b[x, y]
            lr, lg, lb = px_l[x, y]
            px_o[x, y] = (
                min(255, br + lr),
                min(255, bg + lg),
                min(255, bb + lb),
            )
    return base


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius, fill=255)
    out = Image.new("RGB", img.size, (0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out, mask


def fit(img, box_w, box_h):
    """Scale to fit inside the box. A 0 in either axis means 'unconstrained'.

    A 0 is a real value in these calls (a portrait phone is constrained by
    height only), so it must not reach the scale factor — that collapses the
    image to 1px.
    """
    s = 1.0
    if box_w:
        s = min(s, box_w / img.width)
    if box_h:
        s = min(s, box_h / img.height)
    return img.resize(
        (max(1, int(img.width * s)), max(1, int(img.height * s))), Image.LANCZOS
    )


def wrap(draw, text, f, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=f) <= max_w:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def load(rel):
    p = os.path.join(RAW, rel)
    if not os.path.exists(p):
        raise SystemExit(f"missing source screenshot: {p}\n"
                         f"run scripts/capture-asc-raw.sh first")
    return Image.open(p).convert("RGB")


# ---------------------------------------------------------------------------
# Scene 1 — the hero. Phone in a trackpad surface, Mac control panel behind.
# ---------------------------------------------------------------------------
def scene_agent_router(outdir):
    W, H = 1280, 800
    base = gradient((W, H))
    base = add_glow(base, (W - 300, 300), 420, (60, 120, 255), 0.42)
    d = ImageDraw.Draw(base)
    f_kicker = font(FONT_MONO, 20)
    f_title = font(FONT_DISPLAY, 62)
    f_sub = font(FONT_DISPLAY, 26)

    d.text((72, 84), "REMOTECRAB", font=f_kicker, fill=ACCENT)
    for i, line in enumerate(["Your agent finished.", "Your phone buzzed."]):
        d.text((72, 150 + i * 70), line, font=f_title, fill=INK)
    for i, line in enumerate(["One tap drops you into the exact window", "that needs you — not the app, the window."]):
        d.text((72, 320 + i * 38), line, font=f_sub, fill=INK_DIM)

    # The real notification capture, framed like a device.
    shot = load("iphone/en-US/notifications.png")
    ph_h = 600
    ph = fit(shot, 0, ph_h)
    ph, mask = rounded(ph, 34)
    px, py = W - ph.width - 72, (H - ph.height) // 2
    base.paste(ph, (px, py), mask)

    d.text((72, H - 92), "REAL CAPTURE — RELAYED FROM A MAC NOTIFICATION BANNER",
           font=font(FONT_MONO, 17), fill=(150, 140, 185))
    p = os.path.join(outdir, "01-agent-router.png")
    base.save(p)
    return p


# ---------------------------------------------------------------------------
# Scene 2 — four capabilities, one product, one grid.
# ---------------------------------------------------------------------------
def scene_peripherals(outdir):
    W, H = 1280, 800
    base = gradient((W, H), c_a=(14, 16, 40), c_b=(30, 34, 78), c_c=(48, 52, 120))
    base = add_glow(base, (W // 2, 420), 620, (70, 90, 220), 0.30)
    d = ImageDraw.Draw(base)
    d.text((72, 68), "ONE PHONE. FOUR PERIPHERALS.", font=font(FONT_DISPLAY, 48), fill=INK)
    d.text((72, 128), "And none of them go behind a paywall. Ever.",
           font=font(FONT_DISPLAY, 23), fill=INK_DIM)

    cells = [
        ("iphone/en-US/trackpad.png", "TRACKPAD", "Momentum, pinch, force click"),
        ("iphone/en-US/keyboard.png", "KEYBOARD", "System IME, shortcut bar"),
        ("iphone/en-US/camera.png", "CAMERA", "H.264 hardware encode"),
        ("mac/en-US/test-window.png", "MIC + VIDEO", "Live input verification"),
    ]
    cw, gap = 272, 24
    top = 200
    shot_h = 372
    x0 = 72
    f_t = font(FONT_MONO, 21)
    f_s = font(FONT_DISPLAY, 19)
    for i, (rel, title, sub) in enumerate(cells):
        cx = x0 + i * (cw + gap)
        shot = fit(load(rel), cw - 16, shot_h)
        shot, mask = rounded(shot, 24)
        base.paste(shot, (cx + 8, top + 8), mask)
        d.rectangle(
            [cx + 7, top + 7, cx + 9 + shot.width, top + 9 + shot.height],
            outline=(78, 84, 148), width=1,
        )
        d.text((cx + 8, top + shot_h + 44), title, font=f_t, fill=ACCENT)
        for j, line in enumerate(wrap(d, sub, f_s, cw - 8)):
            d.text((cx + 8, top + shot_h + 80 + j * 26), line, font=f_s, fill=INK_DIM)

    d.text((72, H - 58), "REAL CAPTURES — iPHONE AND macOS",
           font=font(FONT_MONO, 17), fill=(140, 146, 190))
    p = os.path.join(outdir, "02-peripherals.png")
    base.save(p)
    return p


# ---------------------------------------------------------------------------
# Scene 3 — context modes. The differentiator nobody else ships.
# ---------------------------------------------------------------------------
def scene_context_modes(outdir):
    W, H = 1280, 800
    base = gradient((W, H), c_a=(16, 12, 34), c_b=(40, 24, 82), c_c=(30, 60, 110))
    base = add_glow(base, (300, 480), 460, (40, 130, 255), 0.36)
    d = ImageDraw.Draw(base)
    d.text((72, 76), "18 CONTROL SUITES.", font=font(FONT_DISPLAY, 50), fill=INK)
    d.text((72, 140), "The shortcut bar reconfigures itself for whatever is frontmost.",
           font=font(FONT_DISPLAY, 24), fill=INK_DIM)

    shot = load("iphone/en-US/context.png")
    ph = fit(shot, 0, 470)
    ph, mask = rounded(ph, 32)
    px, py = 78, 206
    base.paste(ph, (px, py), mask)

    d2_x = px + ph.width + 84
    rows = [
        ("Keynote", "presenter controls"),
        ("Xcode", "build, test, run"),
        ("Terminal", "agent commands"),
        ("Figma", "frame, measure"),
    ]
    f_app = font(FONT_DISPLAY, 32)
    f_what = font(FONT_DISPLAY, 21)
    for i, (app, what) in enumerate(rows):
        y = 250 + i * 96
        d.text((d2_x, y), app, font=f_app, fill=INK)
        d.text((d2_x, y + 42), what, font=f_what, fill=ACCENT)
    d.text((d2_x, 250 + 4 * 96 + 20), "49 apps mapped. First match wins.",
           font=font(FONT_MONO, 19), fill=(150, 140, 185))

    d.text((72, H - 76), "REAL CAPTURE — CONTEXT SHEET, OPENCODE DETECTED",
           font=font(FONT_MONO, 17), fill=(150, 140, 185))
    p = os.path.join(outdir, "03-context-modes.png")
    base.save(p)
    return p


# ---------------------------------------------------------------------------
# The project card. 1024x576 is what KS crops every listing to.
# ---------------------------------------------------------------------------
def project_hero(outdir):
    W, H = 1024, 576
    base = gradient((W, H), c_a=(12, 10, 30), c_b=(46, 26, 90), c_c=(96, 44, 150))
    base = add_glow(base, (W - 300, H // 2), 400, (60, 110, 255), 0.40)
    d = ImageDraw.Draw(base)
    d.text((56, 62), "REMOTECRAB", font=font(FONT_MONO, 22), fill=ACCENT)
    d.text((56, 108), "Your iPhone is a", font=font(FONT_DISPLAY, 56), fill=INK)
    d.text((56, 172), "second screen for", font=font(FONT_DISPLAY, 56), fill=INK)
    d.text((56, 236), "your Mac.", font=font(FONT_DISPLAY, 56), fill=INK)
    d.text((56, 322), "Camera. Mic. Trackpad. Keyboard.", font=font(FONT_DISPLAY, 25), fill=INK_DIM)
    d.text((56, 358), "Free tier stays free forever.", font=font(FONT_DISPLAY, 25), fill=INK_DIM)

    shot = fit(load("iphone/en-US/trackpad.png"), 0, 560)
    shot, mask = rounded(shot, 36)
    px = W - shot.width - 48
    base.paste(shot, (px, (H - shot.height) // 2), mask)
    d.rectangle([px - 1, (H - shot.height) // 2 - 1,
                  px + shot.width, (H - shot.height) // 2 + shot.height],
                 outline=(92, 72, 150), width=1)

    d.text((56, H - 66), "FUNDING PRO ON KICKSTARTER", font=font(FONT_MONO, 18),
           fill=(168, 158, 200))
    p = os.path.join(outdir, "00-project-hero-1024x576.png")
    base.save(p)
    return p


# ---------------------------------------------------------------------------
# 9:16 discovery vertical.
# ---------------------------------------------------------------------------
def discovery_vertical(outdir):
    W, H = 1080, 1920
    base = gradient((W, H), c_a=(10, 9, 26), c_b=(40, 24, 84), c_c=(20, 52, 104))
    base = add_glow(base, (W // 2, 1250), 620, (50, 120, 255), 0.34)
    d = ImageDraw.Draw(base)
    d.text((72, 150), "REMOTECRAB", font=font(FONT_MONO, 34), fill=ACCENT)
    for i, line in enumerate(["Your iPhone is a", "second screen", "for your Mac."]):
        d.text((72, 240 + i * 108), line, font=font(FONT_DISPLAY, 92), fill=INK)
    d.text((72, 640), "Camera. Mic. Trackpad.", font=font(FONT_DISPLAY, 40), fill=INK_DIM)
    d.text((72, 696), "Keyboard. Second display.", font=font(FONT_DISPLAY, 40), fill=INK_DIM)

    shot = fit(load("iphone/en-US/notifications.png"), 0, 840)
    shot, mask = rounded(shot, 46)
    base.paste(shot, ((W - shot.width) // 2, 830), mask)

    d.text((72, H - 260), "Your agent finished.", font=font(FONT_DISPLAY, 46), fill=INK)
    d.text((72, H - 196), "One tap gets you there.", font=font(FONT_DISPLAY, 46), fill=ACCENT)
    d.text((72, H - 110), "FREE TIER FOREVER", font=font(FONT_MONO, 28), fill=(180, 170, 210))
    p = os.path.join(outdir, "00-discovery-9x16.png")
    base.save(p)
    return p


def project_hero_notext(outdir):
    """Text-free variant of the project card.

    Kickstarter explicitly warns that project images with text get penalized by
    the Facebook algorithm and are illegible at small sizes. The text version is
    stronger in a browse context, this one is safer in a share feed — keep both
    and pick at launch.
    """
    W, H = 1024, 576
    base = gradient((W, H), c_a=(12, 10, 30), c_b=(46, 26, 90), c_c=(96, 44, 150))
    base = add_glow(base, (W // 2, H // 2), 520, (60, 110, 255), 0.45)
    d = ImageDraw.Draw(base)

    shots = ["iphone/en-US/trackpad.png", "iphone/en-US/context.png",
             "mac/en-US/test-window.png"]
    card_w, card_h, gap = 288, 400, 20
    x0 = (W - (card_w * 3 + gap * 2)) // 2
    y0 = (H - card_h) // 2
    for i, rel in enumerate(shots):
        shot = fit(load(rel), card_w, card_h)
        shot, mask = rounded(shot, 26)
        cx = x0 + i * (card_w + gap)
        base.paste(shot, (cx, y0), mask)
        d.rectangle([cx - 1, y0 - 1, cx + shot.width, y0 + shot.height],
                    outline=(96, 76, 154), width=1)

    p = os.path.join(outdir, "00-project-hero-notext-1024x576.png")
    base.save(p)
    return p


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "ks-graphics")
    os.makedirs(outdir, exist_ok=True)
    for fn in (project_hero, project_hero_notext, discovery_vertical, scene_agent_router,
               scene_peripherals, scene_context_modes):
        p = fn(outdir)
        print(f"{os.path.relpath(p, ROOT)}  {Image.open(p).size}")
    print(f"\n{len(os.listdir(outdir))} images -> {outdir}")


if __name__ == "__main__":
    main()
