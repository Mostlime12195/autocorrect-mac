#!/bin/bash
# Mirror a Mac release to the PUBLIC models repo and point the in-app updater at it (run on the VPS after CI released
# the mac-v<version> tag here):
#  - zip -> Mostlime12195/keylime-models release mac-v<version>, --latest=false (the Android APKs live there too)
#  - mac-latest.json -> Nest /var/www/autocorrect-android/mac-latest.json
# Usage: scripts/publish.sh 0.1.0
set -euo pipefail
V="${1:?usage: $0 <version>}"
TAG="mac-v$V"
REPO=Mostlime12195/keylime-mac
PUB=Mostlime12195/keylime-models
HOST=mostlime@hackclub.app
DIR=/var/www/autocorrect-android
BASE=https://autocorrect.mostlime.hackclub.app/autocorrect-android
ZIP="Keylime-mac-$V.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

gh release download "$TAG" -R "$REPO" -p "$ZIP" -D "$TMP"
F="$TMP/$ZIP"
SHA=$(sha256sum "$F" | cut -d' ' -f1)
SIZE=$(stat -c %s "$F")
NOTES="${NOTES:-Keylime for Mac $V (Apple Silicon, macOS 13+). Self-signed, not notarized: first launch with right-click > Open, or xattr -dr com.apple.quarantine /Applications/Keylime.app}"

if gh release view "$TAG" -R "$PUB" >/dev/null 2>&1; then
  gh release upload "$TAG" "$F" -R "$PUB" --clobber
else
  gh release create "$TAG" "$F" -R "$PUB" --latest=false --title "Keylime for Mac $V" --notes "$NOTES"
fi
URL="https://github.com/$PUB/releases/download/$TAG/$ZIP"
# wait for propagation, then probe ONLY cache-busted URLs (a plain probe too early caches 404s on the CDN)
sleep 20
chunk() {  # chunk <from> <to> <try>
  local f="$TMP/chunk.bin" code
  code=$(curl -sL --http1.1 -r "$1-$2" -o "$f" -w '%{http_code}' "$URL?cb=$RANDOM$RANDOM$3" || true)
  [ "$code" = 206 ] && cmp -s "$f" <(tail -c +"$(($1 + 1))" "$F" | head -c "$(($2 - $1 + 1))")
}
MID=$((SIZE / 2))
ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if chunk 0 1023 "$i" && chunk "$MID" "$((MID + 1023))" "$i" && chunk "$((SIZE - 1024))" "$((SIZE - 1))" "$i"; then ok=1; break; fi
  echo "asset not served correctly yet (try $i), waiting"; sleep 30
done
[ "$ok" = 1 ] || { echo "the public asset isn't served correctly: not writing mac-latest.json"; exit 1; }
DIGEST=$(gh api "repos/$PUB/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$ZIP\") | .digest // empty")
[ -z "$DIGEST" ] || [ "$DIGEST" = "sha256:$SHA" ] || { echo "GitHub asset digest mismatch: $DIGEST"; exit 1; }
echo "public asset verified: $URL ($SIZE bytes, sha256 $SHA)"

python3 -I -c 'import json,sys; v,u,s,z,n=sys.argv[1:]; print(json.dumps({"version":v,"url":u,"sha256":s,"size":int(z),"notes":n}))' \
  "$V" "$URL" "$SHA" "$SIZE" "$NOTES" > "$TMP/mac-latest.json"

# Nest ssh sometimes drops right after auth: idempotent write, confirmed over https, retried
ok=0
for i in 1 2 3 4 5 6; do
  ssh -o ConnectTimeout=20 "$HOST" "sudo tee $DIR/mac-latest.json.tmp >/dev/null && sudo chmod 644 $DIR/mac-latest.json.tmp && sudo mv $DIR/mac-latest.json.tmp $DIR/mac-latest.json" < "$TMP/mac-latest.json" || true
  if curl -fsS "$BASE/mac-latest.json?cb=$RANDOM$RANDOM" | grep -q "$SHA"; then ok=1; break; fi
  echo "mac-latest.json attempt $i not confirmed, retrying"; sleep 5
done
[ "$ok" = 1 ] || { echo "mac-latest.json update failed"; exit 1; }
curl -fsS "$BASE/mac-latest.json?cb=$RANDOM"; echo
