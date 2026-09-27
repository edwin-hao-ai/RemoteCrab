#!/usr/bin/env bash
#
# Compose a RemoteCrab marketing clip from two sources:
#   • the iPhone side  — a ReplayKit recording made in the app
#                        (Settings → Record a Demo Clip), then saved to Files
#                        or dragged off the device
#   • the Mac side     — either a file you already have, or a live
#                        screencapture started by this script
#
# Output is a 1920x1080 clip: computer on the left, iPhone in a device frame
# on the right, with a title bar.
#
# Why this exists: macOS cannot record a physical iPhone's screen from the
# CLI (simctl is Simulator-only; QuickTime's device route is GUI + a TCC
# prompt that hangs scripts). The app's in-app ReplayKit recorder is the
# permanent workaround — see RemoteCrabCapture/ScreenRecorder.swift. Once the
# phone clip exists, this script does the rest unattended.
#
# Usage
#   # live: script records the Mac while you perform on the phone
#   ./scripts/marketing-video.sh --phone ~/Movies/phone.mp4 --record 30
#
#   # offline: compose two clips you already have
#   ./scripts/marketing-video.sh --phone phone.mp4 --mac mac.mov -o out.mp4
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="docs/marketing/remotecrab-hero.mp4"
PHONE=""
MAC=""
RECORD=0
SECS=30
TITLE="RemoteCrab  ·  your iPhone as a computer's screen, camera, mic, trackpad and keyboard"
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phone)  PHONE="$2"; shift 2 ;;
    --mac)    MAC="$2"; shift 2 ;;
    --record) RECORD=1; SECS="$2"; shift 2 ;;
    --secs)   SECS="$2"; shift 2 ;;
    --title)  TITLE="$2"; shift 2 ;;
    -o|--out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PHONE" ]] && { echo "--phone <recording> is required" >&2; exit 1; }
[[ -f "$PHONE" ]] || { echo "phone clip not found: $PHONE" >&2; exit 1; }
command -v ffmpeg  >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Mac side -------------------------------------------------------------
if [[ $RECORD -eq 1 ]]; then
  [[ -n "$MAC" ]] && { echo "use either --mac or --record, not both" >&2; exit 1; }
  MAC="$TMP/mac.mov"
  echo "recording the Mac for ${SECS}s — perform on the phone NOW"
  # -V records for a fixed duration. Remove -x if you want a click sound.
  screencapture -V "$SECS" -x "$MAC"
  [[ -f "$MAC" ]] || { echo "mac recording failed" >&2; exit 1; }
fi
[[ -n "$MAC" ]] || { echo "--mac <file> or --record <secs> is required" >&2; exit 1; }
[[ -f "$MAC" ]] || { echo "mac clip not found: $MAC" >&2; exit 1; }

# --- 2. geometry -------------------------------------------------------------
# Canvas is 1920x1080 plus a 96px title bar. The phone column is sized from the
# phone clip's own aspect ratio, then the Mac is fitted into whatever is left —
# computed in that order so the output is always exactly 1920 wide.
CANVAS_W=1920
CANVAS_H=1080
PHONE_H=940          # device screen height inside the frame
PAD=28               # frame padding around the screen

PH_W_H=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0 "$PHONE")
PH_W=${PH_W_H%%,*}; PH_H=${PH_W_H##*,}
[[ -n "$PH_W" && -n "$PH_H" && "$PH_W" != "N/A" ]] || {
  echo "could not probe the phone clip" >&2; exit 1; }
# Scale the phone to the frame's inner height. Done in shell rather than with
# a lavfi probe — that spins up a whole filter graph just to read a number, and
# it can hang. Forced even because H.264 needs even dimensions.
PH_SCALED_W=$(( (PH_W * PHONE_H + PH_H / 2) / PH_H ))
PH_SCALED_W=$(( PH_SCALED_W & ~1 ))
FRAME_W=$(( PH_SCALED_W + PAD * 2 ))
FRAME_H=$(( PHONE_H + PAD * 2 ))
[[ $FRAME_W -lt $CANVAS_W ]] || { echo "phone clip is too wide to compose" >&2; exit 1; }
MAC_W=$(( CANVAS_W - FRAME_W ))

# The shortest source bounds the output, so the still mask can be read as a
# single frame and alphamerge holds it. A looped image would never terminate.
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$PHONE" 2>/dev/null)
DUR_MAC=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MAC" 2>/dev/null)
if [[ -n "$DUR" && -n "$DUR_MAC" ]]; then
  DUR=$(python3 -c "print(f'{max(min($DUR, $DUR_MAC)-0.2, 0.5):.3f}')")
fi
[[ -n "$DUR" ]] || DUR=60

echo "phone ${PH_W}x${PH_H} -> frame ${FRAME_W}x${FRAME_H}   mac column ${MAC_W}x${CANVAS_H}   ${DUR}s"

# --- 3. device frame + corner mask -------------------------------------------
# ffmpeg's drawbox has no rounded corners, so both the device body and the
# rounded screen cutout are drawn with Pillow:
#   frame.png — the RGBA body (only the bezel and the notch-free outline)
#   mask.png  — greyscale rounded rect; ffmpeg's alphamerge reads its luma as
#               alpha, which is what rounds the video's own corners
python3 - "$TMP" "$FRAME_W" "$FRAME_H" "$PAD" <<'PY'
import sys, os
from PIL import Image, ImageDraw

tmp, w, h, pad = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
r = 54                                    # body corner radius
screen_r = max(r - pad, 8)               # screen corner radius

body = Image.new('RGBA', (w, h), (0, 0, 0, 0))
ImageDraw.Draw(body).rounded_rectangle([0, 0, w - 1, h - 1], radius=r,
                                       fill=(22, 22, 28, 255))
body.save(os.path.join(tmp, 'frame.png'))

mask = Image.new('L', (w, h), 0)
ImageDraw.Draw(mask).rounded_rectangle([pad, pad, w - pad - 1, h - pad - 1],
                                       radius=screen_r, fill=255)
mask.save(os.path.join(tmp, 'mask.png'))
print('frame', body.size, 'mask', mask.size)
PY
[[ -f "$TMP/frame.png" && -f "$TMP/mask.png" ]] || {
  echo "frame generation failed (Pillow missing?)" >&2; exit 1; }

# --- 4. compose --------------------------------------------------------------
# The title goes through a text file, not text='...': an apostrophe in the
# title (e.g. "computer's") would terminate drawtext's quoting and be parsed
# as a filter name. The graph is also built on one line for the same reason.
printf '%s' "$TITLE" > "$TMP/title.txt"

GRAPH="[0:v]scale=${MAC_W}:${CANVAS_H}:force_original_aspect_ratio=decrease,pad=${MAC_W}:${CANVAS_H}:(ow-iw)/2:(oh-ih)/2:color=0x0a0a0f,fps=30,setpts=PTS-STARTPTS[mac];"
GRAPH+="[1:v]scale=-2:${PHONE_H},fps=30,pad=${FRAME_W}:${FRAME_H}:(ow-iw)/2:(oh-ih)/2:color=black,setpts=PTS-STARTPTS[phpad];"
GRAPH+="[phpad][2:v]alphamerge[framed];"
GRAPH+="[framed]pad=iw:${CANVAS_H}:0:(oh-ih)/2:color=0x0a0a0f[phonecol];"
GRAPH+="[mac][phonecol]hstack=inputs=2[body];"
GRAPH+="[body]pad=iw:ih+96:0:96:color=0x0a0a0f,drawtext=fontfile=${FONT}:textfile=${TMP}/title.txt:fontcolor=white:fontsize=34:x=(w-text_w)/2:y=32[v]"

if ! ffmpeg -loglevel error -y \
  -i "$MAC" -i "$PHONE" -i "$TMP/mask.png" \
  -filter_complex "$GRAPH" \
  -map "[v]" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 \
  -t "$DUR" "$OUT"; then
  echo "compose failed" >&2
  exit 1
fi

echo "wrote $OUT"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration \
  -of default=nw=1 "$OUT"
[[ $RECORD -eq 1 ]] && rm -f "$TMP/mac.mov"
echo
echo "next:"
echo "  upload:  cat '$OUT' | ssh root@158.247.219.230 'cat > /var/www/vgoapp/downloads/RemoteCrab-hero.mp4'"
echo "  poster:  ffmpeg -i '$OUT' -ss 2 -frames:v 1 docs/marketing/poster.png"
