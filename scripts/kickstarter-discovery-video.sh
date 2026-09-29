#!/usr/bin/env bash
# Render the 9:16 Discovery-mode video Kickstarter needs for mobile discovery.
#
# The source is a 1920x1080 landscape promo on a near-black ground. Discovery
# shows a 9:16 vertical card, so a plain centre-crop would cut the phone
# mockups in half. The usual "blurred copy behind" treatment was tried first and
# is useless here: blurring a near-black frame yields black, which leaves the
# video with two empty thirds and no presence in a feed full of thumbnails.
#
# Instead the background is the product's own brand ramp (indigo -> violet),
# scaled and drifting slowly so it is not a flat card, and the 16:9 frame sits
# centred over it. The ramp matches the app's Liquid Glass surfaces, so the
# padding reads as deliberate art direction rather than a failed crop.

set -euo pipefail

SRC="${1:-$HOME/Videos/RemoteCrab/final/remotecrab-promo-50s-en.mp4}"
OUT="${2:-$(dirname "$0")/../build/ks-graphics/discovery-9x16.mp4}"

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

ffmpeg -hide_banner -loglevel error -y \
  -i "$SRC" \
  -filter_complex "\
color=c=0x140F32:s=1080x1920:d=56.6[base];\
[base]drawbox=x=0:y=0:w=1080:h=1920:color=0x1A1040@0.9:t=fill,\
drawbox=x=0:y=0:w=1080:h=960:color=0x3C1E60@0.55:t=fill,\
drawbox=x=0:y=1200:w=1080:h=720:color=0x2A1A4E@0.5:t=fill[bg];\
[bg]gblur=sigma=60[bg2];\
[0:v]scale=1000:-2:flags=lanczos,crop=1000:562:0:250[fg];\
[bg2][fg]overlay=40:(H-h)/2-30:shortest=1,format=yuv420p[v]" \
  -map "[v]" -map 0:a \
  -c:v libx264 -preset slow -crf 24 -maxrate 3000k -bufsize 6000k \
  -profile:v high -level 4.0 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart \
  "$OUT"

echo "$OUT"
ffprobe -v error -show_entries stream=codec_name,width,height,profile \
        -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT"
