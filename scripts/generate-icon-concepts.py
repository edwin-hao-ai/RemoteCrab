#!/usr/bin/env python3
"""Render polished iBridge app-icon concept drafts.

Dark "Pro tool" style: deep navy gradient background, glowing
signal-cyan glyphs. Everything is drawn at 4x and Lanczos-downscaled
for crisp anti-aliasing.

Outputs 1024x1024 PNGs into assets/concepts/.
"""

import math
import os
from PIL import Image, ImageDraw, ImageFilter

SS = 4                # supersample factor
SIZE = 1024           # final output size
S = SIZE * SS         # working canvas

# Palette ------------------------------------------------------------------
BG_TOP = (13, 24, 44)        # deep navy
BG_BOTTOM = (4, 7, 14)       # near-black blue
GLOW = (76, 201, 240)        # signal cyan
INK_HI = (255, 255, 255)     # glyph highlight
INK_LO = (123, 223, 242)     # glyph lowlight (light cyan)
GOLD = (255, 209, 102)       # camera apex dot


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    """Vertical navy gradient + soft radial glow at top center."""
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        row = lerp(BG_TOP, BG_BOTTOM, y / S)
        for x in range(S):
            px[x, y] = row
    img = img.convert("RGBA")

    # radial highlight behind glyph area
    glow = Image.new("L", (S, S), 0)
    gd = ImageDraw.Draw(glow)
    r = int(S * 0.46)
    gd.ellipse([S // 2 - r, int(S * 0.5) - r, S // 2 + r, int(S * 0.5) + r], fill=46)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.10))
    tint = Image.new("RGBA", (S, S), (58, 108, 168, 255))
    img = Image.composite(tint, img, glow)
    return img


def apply_gradient(mask, top_color, bottom_color):
    """Colorize an L-mode mask with a vertical gradient."""
    grad = Image.new("RGBA", (S, S))
    px = grad.load()
    for y in range(S):
        c = lerp(top_color, bottom_color, y / S)
        for x in range(S):
            px[x, y] = (*c, 255)
    grad.putalpha(mask)
    return grad


def glow_layer(mask, color=GLOW, alpha=170, blur=0.016):
    """Soft outer glow from a glyph mask."""
    g = mask.filter(ImageFilter.GaussianBlur(S * blur))
    layer = Image.new("RGBA", (S, S), (*color, 0))
    layer.putalpha(g.point(lambda v: int(v * alpha / 255)))
    return layer


def arc_mask(draw_fn):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    draw_fn(d)
    return m


# ---------------------------------------------------------------------------
def concept_bridge():
    """Three glowing arcs bridging an iPhone glyph and a Mac glyph."""
    img = background()

    cy = S * 0.66  # device top height — every arc springs from here
    cx = S * 0.5
    half_span = S * 0.26

    # --- arcs (hero): elliptical, same chord, rising heights ---
    def draw_arcs(d):
        for b, alpha in [(0.16, 255), (0.235, 190), (0.31, 130)]:
            bb = S * b
            d.arc([cx - half_span, cy - bb, cx + half_span, cy + bb],
                  180, 360, fill=alpha, width=int(S * 0.028))

    m = arc_mask(draw_arcs)
    img.alpha_composite(glow_layer(m, alpha=200, blur=0.02))
    img.alpha_composite(apply_gradient(m, INK_HI, INK_LO))

    # --- devices: tops sit exactly on cy so the arcs spring from them ---
    def draw_devices(d):
        # iPhone (portrait, left)
        w, h = S * 0.095, S * 0.165
        x0, y0 = cx - half_span - w / 2, cy
        d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=w * 0.28, fill=255)
        # dynamic island
        iw = w * 0.42
        d.rounded_rectangle([x0 + (w - iw) / 2, y0 + h * 0.09,
                             x0 + (w + iw) / 2, y0 + h * 0.09 + w * 0.16],
                            radius=w * 0.08, fill=0)
        # Mac (landscape, right)
        w2, h2 = S * 0.135, S * 0.12
        x1, y1 = cx + half_span - w2 / 2, cy
        d.rounded_rectangle([x1, y1, x1 + w2, y1 + h2], radius=w2 * 0.16, fill=255)
        # camera dot
        cd = w2 * 0.07
        d.ellipse([x1 + w2 / 2 - cd, y1 + h2 * 0.13 - cd,
                   x1 + w2 / 2 + cd, y1 + h2 * 0.13 + cd], fill=0)

    dm = arc_mask(draw_devices)
    img.alpha_composite(glow_layer(dm, color=(200, 230, 255), alpha=90, blur=0.012))
    glass = apply_gradient(dm, (255, 255, 255), (205, 225, 245))
    glass.putalpha(dm.point(lambda v: int(v * 0.96)))
    img.alpha_composite(glass)
    return img


# ---------------------------------------------------------------------------
def concept_linked():
    """Portrait ring (iPhone) chain-linked with landscape ring (Mac).

    The weave happens where the portrait ring's RIGHT vertical stroke
    crosses the landscape ring's TOP and BOTTOM horizontal strokes —
    both rings use tight corner radii so the crossing points sit on
    straight segments, not in the corner arcs.
    """
    img = background()
    sw = int(S * 0.036)  # stroke width
    corner = sw * 1.3

    cy = S * 0.52
    # portrait ring (iPhone), left
    pw, ph = S * 0.20, S * 0.34
    p_cx = S * 0.365
    p_box = [p_cx - pw / 2, cy - ph / 2, p_cx + pw / 2, cy + ph / 2]
    # landscape ring (Mac), right, overlapping the portrait's right stroke
    lw, lh = S * 0.34, S * 0.26
    l_cx = S * 0.565
    l_box = [l_cx - lw / 2, cy - lh / 2, l_cx + lw / 2, cy + lh / 2]

    cross_x = p_box[2] - sw / 2     # portrait right stroke center x
    cross_top = l_box[1] + sw / 2   # landscape top stroke center y
    cross_bot = l_box[3] - sw / 2   # landscape bottom stroke center y

    def draw_land(d):
        d.rounded_rectangle(l_box, radius=corner, outline=255, width=sw)

    lm = arc_mask(draw_land)

    def draw_port(d):
        d.rounded_rectangle(p_box, radius=corner, outline=255, width=sw)

    pm = arc_mask(draw_port)

    # True chain-link weave:
    #  - top crossing:    portrait passes OVER  -> punch gap in landscape
    #  - bottom crossing: landscape passes OVER -> punch gap in portrait
    gw, gh = sw * 1.45, sw * 1.45
    ImageDraw.Draw(lm).rounded_rectangle(
        [cross_x - gw / 2, cross_top - gh / 2, cross_x + gw / 2, cross_top + gh / 2],
        radius=gh / 2, fill=0)
    ImageDraw.Draw(pm).rounded_rectangle(
        [cross_x - gw / 2, cross_bot - gh / 2, cross_x + gw / 2, cross_bot + gh / 2],
        radius=gh / 2, fill=0)

    img.alpha_composite(glow_layer(lm, color=(94, 92, 230), alpha=190, blur=0.02))
    img.alpha_composite(apply_gradient(lm, (235, 240, 255), (148, 146, 240)))
    img.alpha_composite(glow_layer(pm, alpha=200, blur=0.02))
    img.alpha_composite(apply_gradient(pm, INK_HI, INK_LO))
    return img


# ---------------------------------------------------------------------------
def concept_stroke():
    """One continuous stroke: two endpoints, arched bridge, camera apex."""
    img = background()

    x0, y0 = S * 0.24, S * 0.66
    x1, y1 = S * 0.76, S * 0.66
    apex = (S * 0.5, S * 0.30)

    # cubic bezier halves: left->apex, apex->right
    def bez(p0, p1, p2, p3, n=160):
        pts = []
        for i in range(n + 1):
            t = i / n
            mt = 1 - t
            x = mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0]
            y = mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1]
            pts.append((x, y))
        return pts

    c1 = ((x0 + apex[0]) / 2 - S * 0.06, y0)
    c2 = (apex[0] - S * 0.10, apex[1])
    c3 = (apex[0] + S * 0.10, apex[1])
    c4 = ((x1 + apex[0]) / 2 + S * 0.06, y1)
    pts = bez((x0, y0), c1, c2, apex, n=400) + bez(apex, c3, c4, (x1, y1), n=400)

    w = int(S * 0.034)

    def draw_path(d):
        # stamp a disc every couple of samples along the curve:
        # perfectly smooth tube, no polyline banding
        r = w / 2
        for i in range(0, len(pts), 2):
            x, y = pts[i]
            d.ellipse([x - r, y - r, x + r, y + r], fill=255)
        x, y = pts[-1]
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)

    m = arc_mask(draw_path)
    img.alpha_composite(glow_layer(m, alpha=210, blur=0.022))
    img.alpha_composite(apply_gradient(m, INK_HI, INK_LO))

    # endpoints
    def draw_dots(d):
        r = S * 0.042
        d.ellipse([x0 - r, y0 - r, x0 + r, y0 + r], fill=255)
        d.ellipse([x1 - r, y1 - r, x1 + r, y1 + r], fill=255)

    dm = arc_mask(draw_dots)
    img.alpha_composite(glow_layer(dm, alpha=160, blur=0.018))
    img.alpha_composite(apply_gradient(dm, (255, 255, 255), (225, 240, 250)))

    # camera apex dot (gold)
    def draw_cam(d):
        r = S * 0.026
        d.ellipse([apex[0] - r, apex[1] - r, apex[0] + r, apex[1] + r], fill=255)

    cm = arc_mask(draw_cam)
    img.alpha_composite(glow_layer(cm, color=GOLD, alpha=200, blur=0.03))
    gold = Image.new("RGBA", (S, S), (*GOLD, 255))
    gold.putalpha(cm)
    img.alpha_composite(gold)
    return img


# ---------------------------------------------------------------------------
def main():
    out_dir = os.path.join(os.path.dirname(__file__), "..", "assets", "concepts")
    os.makedirs(out_dir, exist_ok=True)
    for name, fn in [("a-signal-bridge", concept_bridge),
                     ("b-linked-rings", concept_linked),
                     ("c-single-stroke", concept_stroke)]:
        img = fn().resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
        path = os.path.join(out_dir, f"{name}.png")
        img.save(path)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
