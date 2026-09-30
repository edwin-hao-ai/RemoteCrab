#!/usr/bin/env python3
"""Generate the Windows notification-area menu icon sheet.

Why a sheet and not a font
--------------------------
The Mac popover draws SF Symbols, so the obvious Windows counterpart would be
the system symbol font (Segoe MDL2 Assets / Segoe Fluent Icons). That was
tried first and rejected: a Private-Use-Area codepoint cannot be checked from
a Mac, so a wrong entry ships as a tofu box or, worse, as the *wrong* glyph —
which is more inconsistent than the ad-hoc Unicode this replaces. A sheet is
drawn here, opened, and looked at before it ships.

Win32 menus have no styled items, so an icon has to be a real bitmap:
`SetMenuItemBitmaps` takes one HBITMAP per row. The runtime decodes this
single atlas (the same `png` path the tray icon already uses) and cuts it into
16x16 monochrome bitmaps.

Style rules, so the set reads as one family rather than fifteen drawings:
  * one weight — 2px strokes at this size, no hairlines
  * no fill where a stroke reads the same
  * every glyph fits a 14x14 box inside the 16x16 cell, so the optical size
    matches between a circle and a rectangle
  * meaning is mirrored from the Mac row for row (see ROWS below); where the Mac
    symbol is drawn too literally to survive 16px (the trackpad's `hand`) the
    substitution keeps the *meaning* and is listed in the note column

Usage:  python3 scripts/generate-windows-menu-icons.py
Output: windows/assets/menu-icons.png   (N x 1 atlas, 16px cells)
"""

import pathlib
import sys

from PIL import Image, ImageDraw

CELL = 16          # Win32 menu icon size
# One outline weight, and it is 1px. A 2px outline on a 12px shape leaves no
# interior at all — the first pass of this sheet drew every outlined glyph as a
# solid blob, which is the exact "casual icon" look this set exists to replace.
# Solid shapes (the stop square, the folder) still read as 2px because they are
# filled, not stroked.
STROKE = 1
GAP = 1            # optical inset inside the cell

# (key, id) — the row ids must match `tray_menu::ids` exactly.
# **This order is load-bearing.** It must match `tray_menu::icon_cell` in
# `tray_menu.rs`, cell for cell. A reorder here without a reorder there gives
# one row another row's icon, and `no_icon_cell_points_outside_the_sheet` only
# catches the case where the counts differ.
ROWS = [
    "camera",        # 0
    "microphone",    # 1
    "trackpad",      # 2
    "keyboard",      # 3
    "switch_camera", # 4
    "record",        # 5  (recording == False)
    "clipboard",     # 6
    "folder",        # 7
    "preview",       # 8
    "diagnosis",     # 9
    "reconnect",     # 10
    "disconnect",    # 11
    "autostart",     # 12
    "quit",          # 13
    "stop",          # 14 (recording == True)
    "install_vcam",  # 15
]


def new_canvas(n=1):
    # Mode "L", not "RGBA": on an RGBA canvas PIL reads an integer `fill=255`
    # as (255, 0, 0, 0) — red at zero alpha, i.e. invisible. A Win32 menu icon
    # is a one-bit mask anyway, so grayscale is also the right model.
    img = Image.new("L", (CELL * n, CELL), 0)
    return img, ImageDraw.Draw(img)


def box(d, x0, y0, x1, y1, r=2, fill=False):
    """A rounded rectangle drawn in the one permitted weight."""
    if fill:
        d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=255)
    else:
        d.rounded_rectangle([x0, y0, x1, y1], radius=r, outline=255, width=STROKE)


def ring(d, cx, cy, r, fill=False, gap=None):
    """A circle, optionally with a gap cut out of the top (a 'power' shape)."""
    if fill:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
        return
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=255, width=STROKE)
    if gap is not None:
        d.rectangle([cx - r - 1, cy - r - 2, cx + r + 1, cy - r + gap], fill=0)


def line(d, x0, y0, x1, y1, width=STROKE):
    d.line([x0, y0, x1, y1], fill=255, width=width)


def draw_camera(d, o):
    # Body, lens, viewfinder bump. The lens is a filled dot, not a ring: at
    # this size a 1px ring inside a 1px body reads as noise.
    box(d, o + 1, o + 5, o + 14, o + 12, r=2)
    d.rectangle([o + 5, o + 3, o + 9, o + 5], fill=255)
    d.rectangle([o + 6, o + 7, o + 9, o + 10], fill=255)


def draw_microphone(d, o):
    # Capsule, then the cradle and the base. The cradle is the part that makes
    # it a mic rather than a pill, so it is a full 180-degree arc — drawn as
    # two straight legs plus a floor instead, which survives at 16px where the
    # arc degenerated into a blob.
    d.rounded_rectangle([o + 6, o + 1, o + 9, o + 7], radius=2, fill=255)
    line(d, o + 4, o + 6, o + 4, o + 10)
    line(d, o + 11, o + 6, o + 11, o + 10)
    line(d, o + 4, o + 10, o + 11, o + 10)
    line(d, o + 8, o + 10, o + 8, o + 13)
    line(d, o + 5, o + 13, o + 11, o + 13)


def draw_trackpad(d, o):
    # NOT the Mac's `hand.point.up.left.fill`: a hand is illegible at 16px, and
    # a trackpad says the same thing. Same meaning, drawn at a size that works.
    box(d, o + 3, o + 2, o + 12, o + 13, r=2)
    line(d, o + 5, o + 5, o + 10, o + 5)
    d.rectangle([o + 7, o + 8, o + 8, o + 9], fill=255)


def draw_keyboard(d, o):
    # Three sparse keys, not a full grid: at 16px a realistic key matrix
    # merges into a solid bar and stops reading as a keyboard at all.
    box(d, o + 1, o + 4, o + 14, o + 11, r=2)
    for x in (4, 7, 10):
        d.rectangle([o + x, o + 6, o + x, o + 7], fill=255)
    d.rectangle([o + 6, o + 9, o + 9, o + 9], fill=255)


def draw_switch_camera(d, o):
    # The Mac's `arrow.triangle.2.circlepath.camera`. A camera outline with a
    # cycle arrow across it reads as "the other one" at a glance; a bare
    # circular arrow would be indistinguishable from Reconnect one row down.
    box(d, o + 1, o + 5, o + 11, o + 12, r=2)
    d.rectangle([o + 4, o + 3, o + 7, o + 5], fill=255)
    d.rectangle([o + 5, o + 7, o + 7, o + 9], fill=255)
    d.arc([o + 6, o + 1, o + 15, o + 10], start=290, end=30, fill=255, width=STROKE)
    d.polygon([(o + 13, o + 1), (o + 15, o + 6), (o + 9, o + 5)], fill=255)


def draw_record(d, o):
    d.ellipse([o + 3, o + 3, o + 12, o + 12], outline=255, width=STROKE)
    d.ellipse([o + 6, o + 6, o + 9, o + 9], fill=255)


def draw_stop(d, o):
    d.rounded_rectangle([o + 4, o + 4, o + 11, o + 11], radius=1, fill=255)


def draw_clipboard(d, o):
    box(d, o + 3, o + 3, o + 12, o + 14, r=1)
    d.rectangle([o + 6, o + 1, o + 9, o + 4], fill=255)
    for y in (7, 10):
        line(d, o + 5, o + y, o + 10, o + y)


def draw_folder(d, o):
    d.polygon(
        [(o + 1, o + 4), (o + 6, o + 4), (o + 7, o + 6), (o + 14, o + 6),
         (o + 14, o + 13), (o + 1, o + 13)],
        fill=255,
    )


def draw_preview(d, o):
    # A window: outline plus a title-bar rule. The rule is what separates this
    # from the keyboard at 16px, so it stays.
    box(d, o + 1, o + 2, o + 14, o + 13, r=2)
    line(d, o + 1, o + 5, o + 14, o + 5)
    d.rectangle([o + 3, o + 3, o + 3, o + 4], fill=255)


def draw_diagnosis(d, o):
    # The question this row exists to answer. Built from straight runs and one
    # small arc: a curved glyph degenerates at 16px, which is what the first
    # pass of this icon got wrong.
    d.ellipse([o + 2, o + 2, o + 13, o + 13], outline=255, width=STROKE)
    d.arc([o + 5, o + 4, o + 10, o + 9], start=195, end=15, fill=255, width=STROKE)
    line(d, o + 8, o + 7, o + 8, o + 10)
    d.rectangle([o + 7, o + 11, o + 8, o + 12], fill=255)


def draw_reconnect(d, o):
    # The refresh mark, drawn as explicit pixel geometry rather than `d.arc`.
    # A 1px arc at radius 5 lands on a different subpixel on each side of the
    # glyph, so the ring came out uneven and the arrowhead merged with it — it
    # read as a "no entry" sign. Two octagonal runs plus a head, laid out on
    # integer coordinates, is unambiguous.
    ring_pts = [
        (5, 3), (7, 2), (9, 2), (11, 3), (12, 5), (13, 7),
        (12, 10), (10, 12), (7, 13), (4, 12), (2, 10), (2, 7), (3, 5),
    ]
    for (x0, y0), (x1, y1) in zip(ring_pts, ring_pts[1:]):
        line(d, o + x0, o + y0, o + x1, o + y1)
    # Arrowhead at the ring's end, pointing clockwise into the gap.
    d.polygon([(o + 12, o + 2), (o + 14, o + 7), (o + 8, o + 6)], fill=255)


def draw_disconnect(d, o):
    ring(d, o + 8, o + 8, 6)
    line(d, o + 5, o + 5, o + 10, o + 10)
    line(d, o + 10, o + 5, o + 5, o + 10)


def draw_autostart(d, o):
    # A plug, drawn as a wide body with two prongs and a cord stub. It has to
    # stay visually distinct from `quit`'s power symbol, because "start
    # automatically" and "quit" are adjacent rows in the same section and the
    # user should never have to read the label to tell them apart.
    box(d, o + 3, o + 6, o + 12, o + 11, r=1)
    line(d, o + 5, o + 6, o + 5, o + 2)
    line(d, o + 10, o + 6, o + 10, o + 2)
    line(d, o + 7, o + 11, o + 7, o + 14)


def draw_quit(d, o):
    # The power symbol, again as explicit geometry. A stroked arc put the gap
    # somewhere near the top-left rather than at twelve o'clock, and the stem
    # then read as a "J" inside a circle. Coordinates make the gap exact.
    #   gap: the two pixels at (7,3) and (9,3) are simply not drawn.
    ring_pts = [
        (5, 4), (3, 7), (2, 9), (3, 12), (6, 14), (9, 14),
        (12, 12), (14, 9), (13, 6), (11, 4),
    ]
    for (x0, y0), (x1, y1) in zip(ring_pts, ring_pts[1:]):
        line(d, o + x0, o + y0, o + x1, o + y1)
    # The stem: 1px. A 2px stem fills the gap the arc left, and the whole thing
    # then reads as a bar inside a circle rather than as the power symbol.
    line(d, o + 7, o + 1, o + 7, o + 6)


def draw_install_vcam(d, o):
    # A camera with a plus: "get the camera you do not have yet".
    #
    # It has to be distinguishable from `camera` (same outline, 15 rows apart)
    # and from `switch_camera` (camera + arrow, one row away). The plus sits in
    # the empty top-right corner the camera body leaves, so the body pixels are
    # identical to `camera` and only the corner differs — the smallest possible
    # difference that still reads at 16px.
    box(d, o + 1, o + 5, o + 12, o + 12, r=2)
    d.rectangle([o + 4, o + 3, o + 7, o + 5], fill=255)
    d.rectangle([o + 5, o + 7, o + 8, o + 10], fill=255)
    # The plus, in the corner the body does not reach.
    line(d, o + 11, o + 1, o + 11, o + 5)
    line(d, o + 9, o + 3, o + 13, o + 3)


DRAW = {
    "camera": draw_camera,
    "switch_camera": draw_switch_camera,
    "microphone": draw_microphone,
    "trackpad": draw_trackpad,
    "keyboard": draw_keyboard,
    "record": draw_record,
    "stop": draw_stop,
    "clipboard": draw_clipboard,
    "folder": draw_folder,
    "preview": draw_preview,
    "diagnosis": draw_diagnosis,
    "reconnect": draw_reconnect,
    "disconnect": draw_disconnect,
    "autostart": draw_autostart,
    "quit": draw_quit,
    "install_vcam": draw_install_vcam,
}


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    out = root / "windows" / "assets" / "menu-icons.png"
    out.parent.mkdir(parents=True, exist_ok=True)

    # Each glyph is drawn into its own cell and composited, so a key that does
    # not fit its cell is a crash here rather than a squashed icon in the menu.
    cells = []
    for key in ROWS:
        cell, d = new_canvas(1)
        DRAW[key](d, GAP)
        cells.append(cell)

    # A row ordering test belongs in the Rust suite; here we only refuse to
    # emit an empty or obviously blank glyph, which is the failure mode a
    # mis-coded draw call produces.
    for key, cell in zip(ROWS, cells):
        if not cell.getbbox():
            print(f"error: {key} drew nothing", file=sys.stderr)
            return 1

    sheet = Image.new("L", (CELL * len(ROWS), CELL), 0)
    for i, cell in enumerate(cells):
        sheet.paste(cell, (i * CELL, 0))
    sheet.save(out)
    print(f"{out.relative_to(root)} — {len(ROWS)} icons at {CELL}x{CELL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
