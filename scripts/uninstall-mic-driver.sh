#!/usr/bin/env bash
#
# Remove the RemoteCrab virtual-microphone HAL driver and restart coreaudiod.
#
set -euo pipefail

DEST="/Library/Audio/Plug-Ins/HAL/RemoteCrabMicrophone.driver"

if [ ! -e "$DEST" ]; then
  echo "RemoteCrab Microphone driver is not installed."
  exit 0
fi

echo "Removing $DEST (admin required)…"
sudo rm -rf "$DEST"
echo "Restarting coreaudiod…"
sudo killall coreaudiod 2>/dev/null || true
echo "Done."
