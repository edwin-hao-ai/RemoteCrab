#!/usr/bin/env python3
"""Readiness check for ASC raw captures: the RemoteCrab UI is dark navy,
so a finished render has low mean luminance and some variance. White
launch screens, the mid-launch blob and the home screen all fail.

It must also reject a frame that is really a SYSTEM DIALOG. A grey
"allow RemoteCrab to find devices on your local network?" alert sits on
the same dark background as the app, so the luminance test alone passes it
— which is how a whole batch of ten captures once came back as "ok" while
every one was the local-network prompt. Any large mid-grey region with a
bright, near-white band across its lower third is an alert, not our UI.

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

# --- system-alert rejection -------------------------------------------------
# An iOS permission alert is a light-grey rounded card floating on the dark
# app. Measured on the alert itself the card fills a large share of the
# frame, so a plain "mean is low" test cannot see it.
if ok:
    rgb = Image.open(path).convert("RGB")
    w, h = rgb.size
    small = rgb.resize((80, 174))
    px = small.load()
    light = 0
    total = 80 * 174
    for y in range(174):
        for x in range(80):
            r, g, b = px[x, y]
            # the alert card is a desaturated mid grey, clearly lighter than
            # the app's near-black ground and darker than pure white
            if 110 < r < 205 and abs(r - g) < 22 and abs(g - b) < 22:
                light += 1
    light_ratio = light / total
    reason += f" lightgrey={light_ratio:.4f}"
    if light_ratio > 0.06:
        ok = False
        reason += " <- looks like a system alert"

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
