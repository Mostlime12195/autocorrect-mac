#!/bin/bash
# Release build -> dist/Keylime.app + dist/Keylime-mac-<version>.zip
# Signed with $SIGN_IDENTITY (the "Keylime Self-Signed" certificate: stable designated requirement, so macOS keeps the
# Accessibility grant across updates); ad-hoc when it isn't set (local builds).
# Usage: scripts/build_app.sh <version> [build number]
set -euo pipefail
V="${1:?usage: $0 <version> [build]}"
B="${2:-1}"
ID="${SIGN_IDENTITY:--}"
cd "$(dirname "$0")/.."
scripts/fetch_ort.sh
swift build -c release --arch arm64 --product Keylime
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Keylime"
APP=dist/Keylime.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Keylime"
sed -e "s/__VERSION__/$V/" -e "s/__BUILD__/$B/" App/Info.plist > "$APP/Contents/Info.plist"
cp Resources/lexicon.tsv "$APP/Contents/Resources/"
# app icon: Resources/AppIcon.icns from the 1024 px PNG (sips + iconutil) when it's missing or older
if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon.png -nt Resources/AppIcon.icns ]; then
  SET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o Resources/AppIcon.icns
  rm -rf "$(dirname "$SET")"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# under the name the binary links (@rpath/libonnxruntime.1.dylib), as one real file
NEED=$(otool -L "$APP/Contents/MacOS/Keylime" | awk '/libonnxruntime/ {print $1}' | sed 's#@rpath/##')
cp -L vendor/onnxruntime/lib/libonnxruntime.*.*.*.dylib "$APP/Contents/Frameworks/$NEED"
cp vendor/onnxruntime/LICENSE "$APP/Contents/Resources/onnxruntime-LICENSE.txt"
# the build-tree rpath isn't wanted in the shipped binary
ORT_LIB="$(pwd)/vendor/onnxruntime/lib"
install_name_tool -delete_rpath "$ORT_LIB" "$APP/Contents/MacOS/Keylime" 2>/dev/null || true
otool -L "$APP/Contents/MacOS/Keylime" | grep -i onnxruntime
codesign --force --sign "$ID" --timestamp=none "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$ID" --timestamp=none --identifier dev.mostlime.autocorrect-mac "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
(cd dist && ditto -c -k --keepParent Keylime.app "Keylime-mac-$V.zip")
ls -la dist
