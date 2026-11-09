#!/bin/bash
# Release build -> dist/Autocorrect.app (ad-hoc signed) + dist/Autocorrect-mac-<version>.zip
# Usage: scripts/build_app.sh <version> [build number]
set -euo pipefail
V="${1:?usage: $0 <version> [build]}"
B="${2:-1}"
cd "$(dirname "$0")/.."
scripts/fetch_ort.sh
swift build -c release --arch arm64 --product Autocorrect
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Autocorrect"
APP=dist/Autocorrect.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Autocorrect"
sed -e "s/__VERSION__/$V/" -e "s/__BUILD__/$B/" App/Info.plist > "$APP/Contents/Info.plist"
cp Resources/lexicon.tsv "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp vendor/onnxruntime/lib/libonnxruntime.*.*.*.dylib "$APP/Contents/Frameworks/"
cp vendor/onnxruntime/LICENSE "$APP/Contents/Resources/onnxruntime-LICENSE.txt"
# the build-tree rpath isn't wanted in the shipped binary
ORT_LIB="$(pwd)/vendor/onnxruntime/lib"
install_name_tool -delete_rpath "$ORT_LIB" "$APP/Contents/MacOS/Autocorrect" 2>/dev/null || true
otool -L "$APP/Contents/MacOS/Autocorrect" | grep -i onnxruntime
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign - --timestamp=none --identifier dev.mostlime.autocorrect-mac "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
(cd dist && ditto -c -k --keepParent Autocorrect.app "Autocorrect-mac-$V.zip")
ls -la dist
