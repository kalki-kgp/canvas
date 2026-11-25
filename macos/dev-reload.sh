#!/bin/zsh
# Rebuilds the app and relaunches it (dev loop).
set -euo pipefail
cd "${0:A:h}/.."
osascript -e 'tell application id "me.kalki.canvas" to quit' 2>/dev/null || true
./macos/build.sh "$@"
sleep 1
open macos/build/Canvas.app
