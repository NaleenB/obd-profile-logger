#!/bin/bash
# Regenerates every app icon size from the two cuts of the mark.
#
# Small sizes (16–32 px) use the simplified cut; 64 px and above use the
# detailed one. Run after editing tools/make_icon.swift.
set -euo pipefail

cd "$(dirname "$0")/.."

SET="App/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Rendering masters…"
swift tools/make_icon.swift "$TMP/detailed.png" >/dev/null
swift tools/make_icon.swift "$TMP/small.png" small >/dev/null

mkdir -p "$SET"

emit() { # size  filename  source
  sips -z "$1" "$1" "$3" --out "$SET/$2" >/dev/null
}

# Simplified cut: 16×16, 16@2x (32), 32×32 (32).
emit 16  icon_16x16.png      "$TMP/small.png"
emit 32  icon_16x16@2x.png   "$TMP/small.png"
emit 32  icon_32x32.png      "$TMP/small.png"

# Detailed cut: 64 px and above.
emit 64   icon_32x32@2x.png   "$TMP/detailed.png"
emit 128  icon_128x128.png    "$TMP/detailed.png"
emit 256  icon_128x128@2x.png "$TMP/detailed.png"
emit 256  icon_256x256.png    "$TMP/detailed.png"
emit 512  icon_256x256@2x.png "$TMP/detailed.png"
emit 512  icon_512x512.png    "$TMP/detailed.png"
emit 1024 icon_512x512@2x.png "$TMP/detailed.png"
cp "$TMP/detailed.png" "$SET/AppIcon-1024.png"

echo "Wrote $(ls -1 "$SET"/*.png | wc -l | tr -d ' ') images to $SET"
