#!/bin/zsh
# Builds Canvas.app: the web app (canvas-app), the Swift shell, and the bundle.
#   ./macos/build.sh            build into macos/build/Canvas.app
#   ./macos/build.sh --install  also copy it to /Applications
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
OUT="$ROOT/macos/build"
APP="$OUT/Canvas.app"
VERSION=$(node -p "require('./canvas-app/package.json').version")
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
start=$(date +%s)
step() { echo "[$(( $(date +%s) - start ))s] $*"; }

step "1/4 web app"
(cd canvas-app && npx vite build --logLevel error)

step "2/4 swift"
mkdir -p "$OUT"
swiftc -O -target arm64-apple-macos13.0 \
  -framework AppKit -framework WebKit -framework Network -framework PDFKit -framework Security \
  macos/Sources/*.swift -o "$OUT/Canvas-arm64"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swiftc -O -target x86_64-apple-macos13.0 \
    -framework AppKit -framework WebKit -framework Network -framework PDFKit -framework Security \
    macos/Sources/*.swift -o "$OUT/Canvas-x86_64"
  lipo -create "$OUT/Canvas-arm64" "$OUT/Canvas-x86_64" -output "$OUT/Canvas-bin"
else
  cp "$OUT/Canvas-arm64" "$OUT/Canvas-bin"
fi

step "3/4 icon"
if [[ ! -f "$OUT/AppIcon.icns" || macos/scripts/make-icon.swift -nt "$OUT/AppIcon.icns" ]]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift macos/scripts/make-icon.swift "$OUT/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$OUT/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
fi

step "4/4 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Canvas-bin" "$APP/Contents/MacOS/Canvas"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R canvas-app/build "$APP/Contents/Resources/web"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" macos/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null
step "built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application "Canvas" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Canvas.app
  cp -R "$APP" /Applications/Canvas.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Canvas.app
  step "installed /Applications/Canvas.app"
fi
