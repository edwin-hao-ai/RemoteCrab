#!/usr/bin/env python3
"""Compose App Store Connect narrative screenshots for RemoteCrab.

Reads real UI captures from build/asc-raw/{iphone,ipad,mac}/{locale}/*.png,
titles from scripts/ios-metadata.json (screenshotTitles), and writes
32 composed screenshots to ios-screenshots/{locale}/{key}-{slot}.png.

  key   iphone67 -> canvas 1290x2796   (source: iPhone 17 Pro Max 1320x2868)
  key   ipad129  -> canvas 2064x2752   (source: iPad Pro 13     2064x2752)

Usage:  python3 scripts/compose-asc-screenshots.py [--only SUBSTRING]
"""

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "build" / "asc-raw"
GEN = ROOT / "build" / "asc-gen"
OUT = ROOT / "ios-screenshots"
METADATA = ROOT / "scripts" / "ios-metadata.json"
APP_ICON = GEN / "app-icon.png"  # rasterized from assets/app-icon-liquid.svg

# ---------------------------------------------------------------- palette
BG_TOP = (10, 14, 31)      # #0A0E1F
BG_BOTTOM = (25, 19, 54)   # #191336
BLUE = (10, 132, 255)      # #0A84FF system blue
TITLE_COLOR = (255, 255, 255, 255)
SUB_COLOR = (255, 255, 255, 166)     # white 0.65
LABEL_COLOR = (255, 255, 255, 204)   # white 0.80
STROKE_COLOR = (255, 255, 255, 80)

# ---------------------------------------------------------------- fonts
PINGFANG = "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
SFNS = "/System/Library/Fonts/SFNS.ttf"
APPLE_SYMBOLS = "/System/Library/Fonts/Apple Symbols.ttf"
PF_REGULAR = 3   # PingFang SC Regular
PF_SEMIBOLD = 11  # PingFang SC Semibold
# modifier glyphs PingFang lacks — rendered with Apple Symbols as fallback
SYMBOL_CHARS = set("⌃⌥⌘⇧")


def load_font(locale, weight, size):
    """weight: 'bold' | 'regular'. zh-Hans must use PingFang (SFNS has no CJK)."""
    if locale == "zh-Hans":
        idx = PF_SEMIBOLD if weight == "bold" else PF_REGULAR
        return ImageFont.truetype(PINGFANG, size, index=idx)
    try:
        f = ImageFont.truetype(SFNS, size)
        f.set_variation_by_name("Bold" if weight == "bold" else "Regular")
        return f
    except Exception:
        idx = PF_SEMIBOLD if weight == "bold" else PF_REGULAR
        return ImageFont.truetype(PINGFANG, size, index=idx)


# ---------------------------------------------------------------- subtitles
SUBTITLES = {
    "01-concept":  {"zh-Hans": "纯本地 WiFi 直连 · 无账号 · 无订阅",
                    "en-US": "Local WiFi · No account · No subscription"},
    "02-camera":   {"zh-Hans": "Zoom、Teams、FaceTime、OBS 直接可用",
                    "en-US": "Works in Zoom, Teams, FaceTime and OBS"},
    "03-mic":      {"zh-Hans": "一键安装,全系统可用",
                    "en-US": "One-click install, available system-wide"},
    "04-trackpad": {"zh-Hans": "双指滚动 · 右键 · 三指手势 · ⌃⌥⌘⇧ 修饰键",
                    "en-US": "Scroll, right-click, gestures & modifiers"},
    "05-keyboard": {"zh-Hans": "系统输入法,中文听写都可以",
                    "en-US": "Full IME support — Chinese & dictation"},
    "06-voice":    {"zh-Hans": "端侧语音识别,不上云",
                    "en-US": "On-device recognition, nothing leaves the LAN"},
    "07-files":    {"zh-Hans": "照片文件直发 电脑,Finder 自动打开",
                    "en-US": "Files land in Downloads, revealed in Finder"},
    "08-privacy":  {"zh-Hans": "你的数据,永远不离开你的局域网",
                    "en-US": "Your data never leaves your network"},
}

SLOTS = ["01-concept", "02-camera", "03-mic", "04-trackpad",
         "05-keyboard", "06-voice", "07-files", "08-privacy"]

# per-key title overrides (device names differ on iPad; ios-metadata.json
# stays the iPhone single source of truth)
TITLE_OVERRIDES = {
    "ipad129": {
        "01-concept": {"en-US": "Your iPad is your computer's camera, mic, trackpad & keyboard",
                       "zh-Hans": "你的 iPad,电脑 的摄像头·麦克风·触控板·键盘"},
        "02-camera": {"en-US": "Turn a spare iPad into a 1080p webcam",
                      "zh-Hans": "旧 iPad,变身高清会议摄像头"},
    },
}

# which raw phone capture each slot embeds (None = no device frame)
SLOT_SOURCE = {"01-concept": "trackpad", "02-camera": "camera",
               "03-mic": "trackpad-mic", "04-trackpad": "trackpad",
               "05-keyboard": "keyboard", "06-voice": "trackpad",
               "07-files": "trackpad", "08-privacy": None}

FEATURE_LABELS = {
    "zh-Hans": ["摄像头", "麦克风", "触控板", "键盘"],
    "en-US": ["Camera", "Mic", "Trackpad", "Keyboard"],
}
PRIVACY_ROWS = {
    "zh-Hans": ["纯本地 WiFi 直连", "无需账号", "数据不上云", "无订阅无内购"],
    "en-US": ["Local WiFi only", "No account", "Nothing in the cloud", "No subscription"],
}

# ---------------------------------------------------------------- canvas config
CANVAS = {
    "iphone67": {
        "size": (1290, 2796),
        "title_size": 92, "title_min": 54, "title_top": 150, "title_side": 90,
        "subtitle_size": 44, "subtitle_gap": 26,
        "device_w": 956,           # single-device slots
        "device_top": 680,
        "duo_device_w": 900,       # slots with a Mac card overlapping
        "duo_device_top": 660,
        "mac_card_w": 560, "mac_card_right": 40, "mac_card_bottom": 50,
        "preview_card_w": 560, "preview_card_right": 40,
        "cp_card_h": 720,
        "finder_card_w": 700,
        "concept_phone_w": 480, "concept_phone_x": 70, "concept_phone_top": 700,
        "concept_mac_w": 540, "concept_mac_right": 70, "concept_mac_top": 780,
        "concept_icon_d": 120, "concept_icons_cy": 2300, "concept_label_size": 38,
        "concept_app_icon": 140, "concept_app_icon_top": 90,
        "privacy_title_top": 260, "privacy_rows_top": 1150, "privacy_row_gap": 320,
        "privacy_icon_d": 120, "privacy_text_size": 54,
    },
    "ipad129": {
        "size": (2064, 2752),
        "title_size": 112, "title_min": 64, "title_top": 170, "title_side": 140,
        "subtitle_size": 54, "subtitle_gap": 30,
        "device_w": 1460,
        "device_top": 640,
        "duo_device_w": 1450,
        "duo_device_top": 640,
        "mac_card_w": 950, "mac_card_right": 60, "mac_card_bottom": 70,
        "preview_card_w": 800, "preview_card_right": 60,
        "cp_card_h": 1000,
        "finder_card_w": 1050,
        "concept_phone_w": 700, "concept_phone_x": 180, "concept_phone_top": 780,
        "concept_mac_w": 700, "concept_mac_right": 180, "concept_mac_top": 800,
        "concept_icon_d": 150, "concept_icons_cy": 2330, "concept_label_size": 48,
        "concept_app_icon": 170, "concept_app_icon_top": 110,
        "privacy_title_top": 320, "privacy_rows_top": 1300, "privacy_row_gap": 360,
        "privacy_icon_d": 150, "privacy_text_size": 66,
    },
}

# ------------------------------------------------- source screenshot geometry
# measured on the raw captures (see task notes)
SRC = {
    "iphone67": {  # 1320x2868
        "dir": "iphone",
        "scene_rect": (0, 352, 1320, 2280),      # below top icons, above PTT
        "mic_icon": (572, 2621, 71),             # dock mic icon center + radius
        "ptt_rect": (48, 2364, 1271, 2496),      # hold-to-talk capsule
        "erase_card": (150, 1240, 1170, 1700),   # zh-Hans "waiting for computer" card
    },
    "ipad129": {   # 2064x2752
        "dir": "ipad",
        "scene_rect": (0, 186, 2064, 2430),
        "mic_icon": (970, 2616, 48),
        "ptt_rect": (32, 2444, 2031, 2532),
        "erase_card": None,
    },
}

# preview.png internals (1736x1336)
PREVIEW_CONTENT_TOP = 112
PREVIEW_CAPSULE = (60, 1136, 1676, 1232)

DEV_PAD = 110    # transparent margin around framed device (room for shadow)
CARD_PAD = 80

# ================================================================ primitives


def vgrad(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def alpha_bbox(im, thresh=8):
    a = im.getchannel("A")
    return a.point(lambda v: 255 if v > thresh else 0).getbbox()


def crop_to_alpha(im, pad=2, thresh=8):
    bb = alpha_bbox(im, thresh)
    if not bb:
        return im
    l = max(0, bb[0] - pad)
    t = max(0, bb[1] - pad)
    r = min(im.width, bb[2] + pad)
    b = min(im.height, bb[3] + pad)
    return im.crop((l, t, r, b))


BREAK_AFTER = set(",，、。;；· ")


def _wrap_cjk(text, measure, max_w):
    """Greedy CJK wrap; prefer breaking right after punctuation so lines
    don't start with '·' and words like 摄像头 stay intact."""
    lines, cur = [], ""
    for ch in text:
        if cur and measure(cur + ch) > max_w:
            cut = -1
            for i in range(len(cur) - 1, 0, -1):
                if cur[i - 1] in BREAK_AFTER and cur[i] not in BREAK_AFTER:
                    cut = i
                    break
            if cut > 0:
                lines.append(cur[:cut])
                cur = cur[cut:] + ch
            else:
                lines.append(cur)
                cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines


def fit_lines(draw, text, locale, weight, max_w, start, minimum, max_lines=2):
    """Shrink font until the wrapped text fits max_w in at most max_lines."""
    cjk = locale == "zh-Hans"
    for size in range(start, minimum - 1, -2):
        font = load_font(locale, weight, size)

        def measure(s):
            b = draw.textbbox((0, 0), s, font=font)
            return b[2] - b[0]
        if cjk:
            lines = _wrap_cjk(text, measure, max_w)
        else:
            lines, cur = [], ""
            for wd in text.split(" "):
                t = wd if not cur else cur + " " + wd
                if cur and measure(t) > max_w:
                    lines.append(cur)
                    cur = wd
                else:
                    cur = t
            if cur:
                lines.append(cur)
        if len(lines) <= max_lines and all(measure(l) <= max_w for l in lines):
            return font, lines, size
    font = load_font(locale, weight, minimum)
    return font, [text], minimum


def draw_centered_lines(draw, lines, font, cx, y, fill, line_spacing=1.22):
    size = font.size
    for ln in lines:
        b = draw.textbbox((0, 0), ln, font=font)
        draw.text((cx - (b[2] - b[0]) / 2 - b[0], y), ln, font=font, fill=fill)
        y += size * line_spacing
    return y


def draw_mixed_centered(draw, text, font, cx, y, fill):
    """Centered text; chars in SYMBOL_CHARS use Apple Symbols (PingFang lacks them)."""
    sym = ImageFont.truetype(APPLE_SYMBOLS, font.size)
    runs = []
    for ch in text:
        f = sym if ch in SYMBOL_CHARS else font
        if runs and runs[-1][0] is f:
            runs[-1][1] += ch
        else:
            runs.append([f, ch])
    widths = []
    for f, s in runs:
        b = draw.textbbox((0, 0), s, font=f)
        widths.append(b[2] - b[0])
    x = cx - sum(widths) / 2
    max_h = 0
    for (f, s), w in zip(runs, widths):
        b = draw.textbbox((0, 0), s, font=f)
        draw.text((x - b[0], y), s, font=f, fill=fill)
        max_h = max(max_h, b[3] - b[1])
        x += w
    return y + max_h


def draw_title_block(canvas, locale, title, subtitle, cfg, top=None):
    d = ImageDraw.Draw(canvas)
    W, _ = canvas.size
    max_w = W - 2 * cfg["title_side"]
    y = top if top is not None else cfg["title_top"]
    font, lines, _ = fit_lines(d, title, locale, "bold", max_w,
                               cfg["title_size"], cfg["title_min"])
    y = draw_centered_lines(d, lines, font, W / 2, y, TITLE_COLOR)
    y += cfg["subtitle_gap"]
    sf = load_font(locale, "regular", cfg["subtitle_size"])
    return draw_mixed_centered(d, subtitle, sf, W / 2, y, SUB_COLOR)


# ================================================================ scene gen


def make_scene(w, h, variant):
    """Bright video-call scene: daylight room, soft window, person at camera.

    Person occupies ~35-40% of frame height; light slate-gray head + smooth
    half-ellipse shoulders with a soft rim light. Nothing dark or hooded.
    """
    if variant == "A":   # warm daylight room
        top, bot = (214, 219, 229), (158, 172, 193)
        win = (252, 246, 232)
        glow = (255, 226, 192)
        person = (119, 132, 154)
        rim = (238, 242, 249)
    else:                # cooler daylight room
        top, bot = (200, 212, 227), (136, 154, 180)
        win = (246, 250, 255)
        glow = (196, 218, 248)
        person = (108, 124, 148)
        rim = (232, 240, 250)
    img = vgrad(w, h, top, bot).convert("RGBA")

    # soft window light, upper-left + faint fill upper-right
    light = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light)
    ld.rounded_rectangle([w * 0.07, h * 0.05, w * 0.40, h * 0.46],
                         radius=int(w * 0.05), fill=win + (205,))
    ld.rounded_rectangle([w * 0.62, h * 0.10, w * 0.92, h * 0.34],
                         radius=int(w * 0.05), fill=glow + (60,))
    img = Image.alpha_composite(img, light.filter(ImageFilter.GaussianBlur(w * 0.045)))
    # gentle floor shading so the lower third grounds the person
    floor = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(floor).rectangle([0, h * 0.78, w, h], fill=(70, 84, 105, 60))
    img = Image.alpha_composite(img, floor.filter(ImageFilter.GaussianBlur(w * 0.05)))

    def person_layer(color, dx=0.0, dy=0.0):
        lay = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        pd = ImageDraw.Draw(lay)
        cx = w * 0.5 + dx
        head_r = h * 0.125
        head_cy = h * 0.46 + dy
        pd.ellipse([cx - head_r, head_cy - head_r, cx + head_r, head_cy + head_r],
                   fill=color + (255,))
        sh_hw = head_r * 2.5          # shoulder half-width
        sh_top = head_cy + head_r * 0.45
        sh_h = h * 0.17
        pd.pieslice([cx - sh_hw, sh_top, cx + sh_hw, sh_top + 2 * sh_h],
                    180, 360, fill=color + (255,))
        return lay

    # rim light: same shape in near-white, offset up-left, behind the body
    rim_lay = person_layer(rim, dx=-w * 0.007, dy=-w * 0.007)
    img = Image.alpha_composite(img, rim_lay.filter(ImageFilter.GaussianBlur(w * 0.006)))
    body = person_layer(person)
    img = Image.alpha_composite(img, body.filter(ImageFilter.GaussianBlur(w * 0.002)))
    return img


# ================================================================ device frame


def make_device(screenshot, screen_w):
    """Frame a screenshot as a device: black bezel, white rim, drop shadow."""
    sw = screen_w
    sh = round(screenshot.height * sw / screenshot.width)
    screen = screenshot.resize((sw, sh), Image.LANCZOS)
    sr = round(sw * 0.11)
    bz = max(10, round(sw * 0.026))
    bw, bh = sw + 2 * bz, sh + 2 * bz
    W, H = bw + 2 * DEV_PAD, bh + 2 * DEV_PAD
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([DEV_PAD, DEV_PAD + 30, DEV_PAD + bw, DEV_PAD + 30 + bh],
                         radius=sr + bz, fill=(0, 0, 0, 115))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(45)))

    d = ImageDraw.Draw(img)
    d.rounded_rectangle([DEV_PAD, DEV_PAD, DEV_PAD + bw, DEV_PAD + bh],
                        radius=sr + bz, fill=(8, 8, 12, 255))
    img.paste(screen, (DEV_PAD + bz, DEV_PAD + bz), rounded_mask((sw, sh), sr))
    d.rounded_rectangle([DEV_PAD, DEV_PAD, DEV_PAD + bw, DEV_PAD + bh],
                        radius=sr + bz, outline=STROKE_COLOR, width=3)
    return img


def make_mac_card(path, target_w=None, target_h=None, crop=True):
    """computer window inside a soft-shadowed rounded card (window kept as-is)."""
    im = Image.open(path).convert("RGBA")
    if crop:
        im = crop_to_alpha(im, pad=2)
    if target_w:
        s = target_w / im.width
    else:
        s = target_h / im.height
    w, h = round(im.width * s), round(im.height * s)
    im = im.resize((w, h), Image.LANCZOS)
    W, H = w + 2 * CARD_PAD, h + 2 * CARD_PAD
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([CARD_PAD, CARD_PAD + 22, CARD_PAD + w, CARD_PAD + 22 + h],
                         radius=24, fill=(0, 0, 0, 100))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(36)))
    img.paste(im, (CARD_PAD, CARD_PAD), im)
    return img


# ================================================================ annotations


def glow_ring(base, kind, geom, pad, width):
    """Blue annotation ring (circle or rounded rect) with outer glow."""
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    if kind == "circle":
        cx, cy, r = geom
        box = [cx - r - pad, cy - r - pad, cx + r + pad, cy + r + pad]
        d.ellipse(box, outline=BLUE + (255,), width=width)
    else:
        x0, y0, x1, y1 = geom
        box = [x0 - pad, y0 - pad, x1 + pad, y1 + pad]
        d.rounded_rectangle(box, radius=(y1 - y0) / 2 + pad,
                            outline=BLUE + (255,), width=width)
    glow = layer.filter(ImageFilter.GaussianBlur(width * 1.8))
    base = Image.alpha_composite(base, glow)
    base = Image.alpha_composite(base, layer)
    return base


def erase_region(base, rect):
    """Paint over a UI card with the surrounding background (row-wise fill)."""
    import statistics
    x0, y0, x1, y1 = rect
    px = base.load()
    for y in range(y0, y1):
        samples = [px[x, y][:3] for x in range(60, 140, 8)]
        r = int(statistics.median(s[0] for s in samples))
        g = int(statistics.median(s[1] for s in samples))
        b = int(statistics.median(s[2] for s in samples))
        for x in range(x0, x1):
            px[x, y] = (r, g, b, 255)
    return base


# ================================================================ line icons


def _arc(d, box, start, end, fill, width):
    d.arc(box, start=start, end=end, fill=fill, width=width)


def draw_feature_icon(d, name, cx, cy, s, color=(255, 255, 255, 255), width=None):
    """Hand-drawn style white line icons inside a box of size s centered at cx,cy."""
    w = width or max(4, round(s * 0.09))
    x0, y0, x1, y1 = cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2
    if name == "camera":
        d.rounded_rectangle([x0 + s * 0.04, y0 + s * 0.16, x1 - s * 0.04, y1 - s * 0.16],
                            radius=s * 0.18, outline=color, width=w)
        d.ellipse([cx - s * 0.15, cy - s * 0.15, cx + s * 0.15, cy + s * 0.15],
                  outline=color, width=w)
    elif name == "mic":
        d.rounded_rectangle([cx - s * 0.16, y0, cx + s * 0.16, cy + s * 0.10],
                            radius=s * 0.16, outline=color, width=w)
        _arc(d, [cx - s * 0.32, cy - s * 0.18, cx + s * 0.32, cy + s * 0.30],
             20, 160, color, w)
        d.line([cx, cy + s * 0.30, cx, y1], fill=color, width=w)
        d.line([cx - s * 0.18, y1, cx + s * 0.18, y1], fill=color, width=w)
    elif name == "trackpad":
        d.rounded_rectangle([x0, y0, x1, y1], radius=s * 0.18, outline=color, width=w)
        d.ellipse([cx - s * 0.10, cy - s * 0.16, cx + s * 0.10, cy + s * 0.04],
                  outline=color, width=w)
        _arc(d, [cx - s * 0.26, cy - s * 0.32, cx + s * 0.26, cy + s * 0.20],
             200, 340, color, w)
    elif name == "keyboard":
        k = s * 0.24
        gap = s * 0.09
        total = 3 * k + 2 * gap
        for r in range(2):
            for c in range(3):
                kx = cx - total / 2 + c * (k + gap)
                ky = cy - (2 * k + gap) / 2 + r * (k + gap)
                d.rounded_rectangle([kx, ky, kx + k, ky + k], radius=k * 0.25,
                                    outline=color, width=max(3, w - 1))
    elif name == "wifi":
        for rr in (0.46, 0.31, 0.16):
            _arc(d, [cx - s * rr, cy - s * rr + s * 0.16, cx + s * rr, cy + s * rr + s * 0.16],
                 205, 335, color, w)
        d.ellipse([cx - s * 0.055, cy + s * 0.30, cx + s * 0.055, cy + s * 0.41], fill=color)
    elif name == "no-person":
        d.ellipse([cx - s * 0.12, y0 + s * 0.08, cx + s * 0.12, y0 + s * 0.32],
                  outline=color, width=w)
        _arc(d, [cx - s * 0.34, cy - s * 0.04, cx + s * 0.34, cy + s * 0.44],
             195, 345, color, w)
        d.line([x0 + s * 0.10, y1 - s * 0.10, x1 - s * 0.10, y0 + s * 0.10],
               fill=color, width=w)
    elif name == "no-cloud":
        _arc(d, [cx - s * 0.36, cy - s * 0.06, cx - s * 0.04, cy + s * 0.22], 95, 250, color, w)
        _arc(d, [cx - s * 0.20, cy - s * 0.28, cx + s * 0.16, cy + s * 0.08], 175, 355, color, w)
        _arc(d, [cx + s * 0.02, cy - s * 0.08, cx + s * 0.36, cy + s * 0.22], 285, 85, color, w)
        d.line([cx - s * 0.20, cy + s * 0.22, cx + s * 0.20, cy + s * 0.22], fill=color, width=w)
        d.line([x0 + s * 0.10, y1 - s * 0.10, x1 - s * 0.10, y0 + s * 0.10],
               fill=color, width=w)
    elif name == "no-card":
        d.rounded_rectangle([x0 + s * 0.04, y0 + s * 0.18, x1 - s * 0.04, y1 - s * 0.18],
                            radius=s * 0.12, outline=color, width=w)
        d.line([x0 + s * 0.04, y0 + s * 0.38, x1 - s * 0.04, y0 + s * 0.38],
               fill=color, width=w)
        d.line([x0 + s * 0.08, y1 - s * 0.08, x1 - s * 0.08, y0 + s * 0.08],
               fill=color, width=w)


def draw_link_arc(canvas, p0, p1, lift=90):
    """Curved double-headed arrow with a small wifi glyph at its midpoint."""
    d = ImageDraw.Draw(canvas)
    mx, my = (p0[0] + p1[0]) / 2, min(p0[1], p1[1]) - lift
    pts = []
    for t in [i / 40 for i in range(41)]:
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * mx + t ** 2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * my + t ** 2 * p1[1]
        pts.append((x, y))
    d.line(pts, fill=BLUE + (255,), width=8, joint="curve")

    def head(tip, prev):
        ang = math.atan2(tip[1] - prev[1], tip[0] - prev[0])
        for da in (2.6, -2.6):
            d.line([tip, (tip[0] + 34 * math.cos(ang + da),
                          tip[1] + 34 * math.sin(ang + da))],
                   fill=BLUE + (255,), width=8)
    head(pts[-1], pts[-5])
    head(pts[0], pts[4])
    q = pts[20]
    draw_feature_icon(d, "wifi", q[0], q[1] - 26, 74,
                      color=(255, 255, 255, 235), width=8)


def draw_arrow(canvas, p0, p1, lift=120, width=9):
    d = ImageDraw.Draw(canvas)
    mx = (p0[0] + p1[0]) / 2
    my = min(p0[1], p1[1]) - lift
    pts = []
    for t in [i / 30 for i in range(31)]:
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * mx + t ** 2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * my + t ** 2 * p1[1]
        pts.append((x, y))
    d.line(pts, fill=BLUE + (255,), width=width, joint="curve")
    tip, prev = pts[-1], pts[-4]
    ang = math.atan2(tip[1] - prev[1], tip[0] - prev[0])
    for da in (2.6, -2.6):
        d.line([tip, (tip[0] + 30 * math.cos(ang + da),
                      tip[1] + 30 * math.sin(ang + da))],
               fill=BLUE + (255,), width=width)


# ================================================================ source prep


def source_is_usable(path):
    """Reject accidental captures (home screen / blank white) — the real app
    UI is a dark theme, so anything bright is not a valid app screenshot."""
    im = Image.open(path).convert("RGB").resize((132, 287))
    return float(np.asarray(im).mean()) < 80.0


def has_green_status_icon(im):
    """Top-left green check = connected state (new captures have no waiting
    card, so the erase patch must not fire and paint over clean UI)."""
    a = np.asarray(im.crop((50, 240, 220, 370)).convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return int(((g > 150) & (g - r > 50) & (g - b > 50)).sum()) > 200


def fix_ipad_en_statusbar(im):
    """en-US iPad captures show a Chinese date in the status bar; cover it and
    redraw it in English (measured: time x52..127, date x151..310, y20..44)."""
    a = np.asarray(im.crop((420, 18, 620, 46)).convert("RGB")).astype(int)
    bg = tuple(int(v) for v in np.median(a.reshape(-1, 3), axis=0))
    d = ImageDraw.Draw(im)
    d.rectangle([136, 8, 345, 56], fill=bg + (255,))
    f = ImageFont.truetype(SFNS, 30)
    d.text((151, 18), "Tue Sep 15", font=f, fill=(255, 255, 255, 255))
    return im


def load_phone_shot(key, locale, name, edits=()):
    im = Image.open(RAW / SRC[key]["dir"] / locale / f"{name}.png").convert("RGBA")
    geo = SRC[key]
    if key == "ipad129" and locale == "en-US":
        im = fix_ipad_en_statusbar(im)
    for edit in edits:
        if edit == "erase-card" and geo["erase_card"] and not has_green_status_icon(im):
            im = erase_region(im, geo["erase_card"])
        elif edit == "scene":
            x0, y0, x1, y1 = geo["scene_rect"]
            scene = make_scene(x1 - x0, y1 - y0, "A")
            im.paste(scene, (x0, y0))
        elif edit == "mic-ring":
            im = glow_ring(im, "circle", geo["mic_icon"], pad=26, width=12)
        elif edit == "ptt-ring":
            im = glow_ring(im, "rect", geo["ptt_rect"], pad=24, width=12)
    return im


def load_preview_with_scene(locale):
    im = Image.open(RAW / "mac" / locale / "preview.png").convert("RGBA")
    orig = im.copy()
    scene = make_scene(im.width, im.height - PREVIEW_CONTENT_TOP, "B")
    im.paste(scene, (0, PREVIEW_CONTENT_TOP))
    c = PREVIEW_CAPSULE
    im.paste(orig.crop(c), (c[0], c[1]))
    im.putalpha(orig.getchannel("A"))
    return im


# ================================================================ slots


def paste_body(canvas, framed, body_x, body_y, pad):
    canvas.paste(framed, (round(body_x) - pad, round(body_y) - pad), framed)


def slot_single(canvas, key, locale, cfg, shot, edits=()):
    phone = make_device(load_phone_shot(key, locale, shot, edits), cfg["device_w"])
    x = (canvas.width - (phone.width - 2 * DEV_PAD)) / 2
    paste_body(canvas, phone, x, cfg["device_top"], DEV_PAD)


def slot_01(canvas, key, locale, cfg):
    W, H = canvas.size
    # app icon above the title
    icon = Image.open(APP_ICON).convert("RGBA").resize(
        (cfg["concept_app_icon"],) * 2, Image.LANCZOS)
    mask = rounded_mask(icon.size, round(icon.width * 0.23))
    canvas.paste(icon, (round((W - icon.width) / 2), cfg["concept_app_icon_top"]), mask)

    phone = make_device(load_phone_shot(key, locale, "trackpad", ("erase-card",)),
                        cfg["concept_phone_w"])
    mac = make_mac_card(RAW / "mac" / locale / "control-panel.png",
                        target_h=None, target_w=cfg["concept_mac_w"])
    pw = phone.width - 2 * DEV_PAD
    ph = phone.height - 2 * DEV_PAD
    mw = mac.width - 2 * CARD_PAD
    mh = mac.height - 2 * CARD_PAD
    px, py = cfg["concept_phone_x"], cfg["concept_phone_top"]
    mx = W - cfg["concept_mac_right"] - mw
    my = cfg["concept_mac_top"]

    # link arc in the gap, behind the devices
    draw_link_arc(canvas, (px + pw - 6, py + ph * 0.26), (mx + 10, my + mh * 0.26),
                  lift=110)
    canvas.paste(mac, (round(mx) - CARD_PAD, round(my) - CARD_PAD), mac)
    canvas.paste(phone, (round(px) - DEV_PAD, round(py) - DEV_PAD), phone)

    # feature icon row
    d = ImageDraw.Draw(canvas)
    labels = FEATURE_LABELS[locale]
    names = ["camera", "mic", "trackpad", "keyboard"]
    dia = cfg["concept_icon_d"]
    cy = cfg["concept_icons_cy"]
    lf = load_font(locale, "regular", cfg["concept_label_size"])
    for i, (nm, lb) in enumerate(zip(names, labels)):
        cx = W * (i + 0.5) / 4
        d.ellipse([cx - dia / 2, cy - dia / 2, cx + dia / 2, cy + dia / 2],
                  fill=BLUE + (255,))
        draw_feature_icon(d, nm, cx, cy, dia * 0.52)
        b = d.textbbox((0, 0), lb, font=lf)
        d.text((cx - (b[2] - b[0]) / 2 - b[0], cy + dia / 2 + 18), lb,
               font=lf, fill=LABEL_COLOR)


def slot_02(canvas, key, locale, cfg):
    W, H = canvas.size
    shot = load_phone_shot(key, locale, "camera", ("scene",))
    scale = cfg["duo_device_w"] / shot.width
    phone = make_device(shot, cfg["duo_device_w"])
    pw = phone.width - 2 * DEV_PAD
    x = (W - pw) / 2
    paste_body(canvas, phone, x, cfg["duo_device_top"], DEV_PAD)

    scene_png = GEN / f"preview-scene-{locale}.png"
    load_preview_with_scene(locale).save(scene_png)
    card = make_mac_card(scene_png, target_w=cfg["preview_card_w"], crop=False)
    cw = card.width - 2 * CARD_PAD
    ch = card.height - 2 * CARD_PAD
    # keep the card fully above the PTT capsule so no UI text is clipped
    ptt_top = cfg["duo_device_top"] + SRC[key]["ptt_rect"][1] * scale
    cx = W - cfg["preview_card_right"] - cw
    cy = ptt_top - ch - max(16, round(ch * 0.04))
    canvas.paste(card, (round(cx) - CARD_PAD, round(cy) - CARD_PAD), card)


def slot_03(canvas, key, locale, cfg):
    W, H = canvas.size
    phone = make_device(load_phone_shot(key, locale, "trackpad-mic", ("mic-ring",)),
                        cfg["duo_device_w"])
    pw = phone.width - 2 * DEV_PAD
    x = (W - pw) / 2
    paste_body(canvas, phone, x, cfg["duo_device_top"], DEV_PAD)

    card = make_mac_card(RAW / "mac" / locale / "control-panel.png",
                         target_h=cfg["cp_card_h"])
    cw = card.width - 2 * CARD_PAD
    ch = card.height - 2 * CARD_PAD
    canvas.paste(card, (round(W - cfg["mac_card_right"] - cw) - CARD_PAD,
                        round(H - cfg["mac_card_bottom"] - ch) - CARD_PAD), card)


def slot_07(canvas, key, locale, cfg):
    W, H = canvas.size
    shot = load_phone_shot(key, locale, "trackpad", ("erase-card",))
    scale = cfg["duo_device_w"] / shot.width
    phone = make_device(shot, cfg["duo_device_w"])
    pw = phone.width - 2 * DEV_PAD
    ph = phone.height - 2 * DEV_PAD
    x = (W - pw) / 2
    paste_body(canvas, phone, x, cfg["duo_device_top"], DEV_PAD)

    card = make_mac_card(RAW / "mac" / locale / "finder.png",
                         target_w=cfg["finder_card_w"])
    cw = card.width - 2 * CARD_PAD
    ch = card.height - 2 * CARD_PAD
    # card sits fully inside the canvas, above the PTT capsule
    ptt_top = cfg["duo_device_top"] + SRC[key]["ptt_rect"][1] * scale
    cx = W - cfg["mac_card_right"] - cw
    cy = ptt_top - ch - max(18, round(ch * 0.05))
    canvas.paste(card, (round(cx) - CARD_PAD, round(cy) - CARD_PAD), card)
    # arrow from the phone's frame edge to the card's top-left corner,
    # routed over empty trackpad surface — never across UI text
    draw_arrow(canvas, (x + pw + 6, cy + ch * 0.42), (cx + 44, cy + 18))


def slot_08(canvas, key, locale, cfg, title_bottom):
    W, H = canvas.size
    d = ImageDraw.Draw(canvas)
    rows = PRIVACY_ROWS[locale]
    names = ["wifi", "no-person", "no-cloud", "no-card"]
    dia = cfg["privacy_icon_d"]
    tf = load_font(locale, "regular", cfg["privacy_text_size"])
    gap = dia * 0.55
    pitch = dia * 1.6                       # compact row spacing
    widths = []
    for t in rows:
        b = d.textbbox((0, 0), t, font=tf)
        widths.append(b[2] - b[0])
    group_w = dia + gap + max(widths)
    group_h = dia + 3 * pitch
    x0 = (W - group_w) / 2
    # center the whole group in the space below the title block
    avail_top = title_bottom + 40
    avail_h = H - 120 - avail_top
    top = avail_top + max(0, (avail_h - group_h) / 2)

    # frosted glass card behind the group (drawn on an overlay so the
    # translucent fill actually blends instead of replacing pixels)
    pad_x, pad_y = dia * 0.62, dia * 0.55
    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.rounded_rectangle([x0 - pad_x, top - pad_y, x0 + group_w + pad_x,
                          top + group_h + pad_y],
                         radius=dia * 0.5, fill=(255, 255, 255, 14),
                         outline=(255, 255, 255, 46), width=2)
    canvas.alpha_composite(overlay)

    y = top
    for nm, t in zip(names, rows):
        cy = y + dia / 2
        d.ellipse([x0, y, x0 + dia, y + dia], fill=BLUE + (255,))
        draw_feature_icon(d, nm, x0 + dia / 2, cy, dia * 0.56,
                          width=max(6, round(dia * 0.075)))
        b = d.textbbox((0, 0), t, font=tf)
        d.text((x0 + dia + gap - b[0], cy - (b[3] - b[1]) / 2 - b[1]), t,
               font=tf, fill=(255, 255, 255, 235))
        y += pitch


# ================================================================ main


def compose(key, locale, slot, titles, cfg):
    src = SLOT_SOURCE[slot]
    if src is not None:
        raw = RAW / SRC[key]["dir"] / locale / f"{src}.png"
        if not source_is_usable(raw):
            print(f"SKIP {locale}/{key}-{slot}: {raw.name} looks like an "
                  "accidental capture (home screen/blank), keeping previous output")
            return None

    W, H = cfg["size"]
    canvas = vgrad(W, H, BG_TOP, BG_BOTTOM).convert("RGBA")

    top = None
    if slot == "01-concept":
        top = cfg["concept_app_icon_top"] + cfg["concept_app_icon"] + 36
    elif slot == "08-privacy":
        top = cfg["privacy_title_top"]
    title = TITLE_OVERRIDES.get(key, {}).get(slot, {}).get(locale) \
        or titles[slot][locale]
    title_bottom = draw_title_block(canvas, locale, title,
                                    SUBTITLES[slot][locale], cfg, top=top)

    if slot == "01-concept":
        slot_01(canvas, key, locale, cfg)
    elif slot == "02-camera":
        slot_02(canvas, key, locale, cfg)
    elif slot == "03-mic":
        slot_03(canvas, key, locale, cfg)
    elif slot == "04-trackpad":
        slot_single(canvas, key, locale, cfg, "trackpad", ("erase-card",))
    elif slot == "05-keyboard":
        slot_single(canvas, key, locale, cfg, "keyboard")
    elif slot == "06-voice":
        slot_single(canvas, key, locale, cfg, "trackpad", ("erase-card", "ptt-ring"))
    elif slot == "07-files":
        slot_07(canvas, key, locale, cfg)
    elif slot == "08-privacy":
        slot_08(canvas, key, locale, cfg, title_bottom)

    out_dir = OUT / locale
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{key}-{slot}.png"
    canvas.convert("RGB").save(out)
    return out


def main():
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    titles = json.loads(METADATA.read_text())["screenshotTitles"]
    if not APP_ICON.exists():
        sys.exit(f"missing {APP_ICON} — rasterize assets/app-icon-liquid.svg first")
    GEN.mkdir(parents=True, exist_ok=True)
    outs, skipped = [], []
    for locale in ("zh-Hans", "en-US"):
        for key, cfg in CANVAS.items():
            for slot in SLOTS:
                name = f"{locale}/{key}-{slot}"
                if only and only not in name:
                    continue
                out = compose(key, locale, slot, titles, cfg)
                if out:
                    outs.append(out)
                    print("wrote", out)
                else:
                    skipped.append(name)
    print(f"{len(outs)} screenshots, {len(skipped)} skipped")
    if skipped:
        print("skipped (stale source):", ", ".join(skipped))


if __name__ == "__main__":
    main()
