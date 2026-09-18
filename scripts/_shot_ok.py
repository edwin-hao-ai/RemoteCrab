#!/usr/bin/env python3
"""Readiness check for ASC raw captures: the RemoteCrab UI is dark navy,
so a finished render has low mean luminance and some variance. White
launch screens, the mid-launch blob and the home screen all fail.

With --connected, also reject shots still showing the amber "waiting
for Mac" alert/status accents (we want the paired, streaming state)."""
import sys
from PIL import Image, ImageStat

path = sys.argv[1]
want_connected = "--connected" in sys.argv

img = Image.open(path).convert("L").resize((160, 348))
stat = ImageStat.Stat(img)
ok = stat.mean[0] < 100 and stat.stddev[0] > 5
reason = f"mean={stat.mean[0]:.1f} stddev={stat.stddev[0]:.1f}"

if ok and want_connected:
    rgb = Image.open(path).convert("RGB")
    w, h = rgb.size
    # The "waiting for Mac" alert card sits centered; its amber icon is
    # small relative to the full canvas on iPad, so measure the card
    # region, not the whole frame.
    crop = rgb.crop((int(w * 0.25), int(h * 0.35), int(w * 0.75), int(h * 0.62)))
    crop = crop.resize((160, 100))
    px = crop.load()
    amber = 0
    for y in range(crop.height):
        for x in range(crop.width):
            r, g, b = px[x, y]
            if r > 190 and 110 < g < 210 and b < 110:
                amber += 1
    ratio = amber / (crop.width * crop.height)
    reason += f" center-amber={ratio:.4f}"
    ok = ratio < 0.0008

print(f"{reason} {'OK' if ok else 'NOT-READY'}")
sys.exit(0 if ok else 1)
