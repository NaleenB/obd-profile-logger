#!/bin/bash
# Builds OBDProbe and wraps it in a minimal .app bundle so macOS attributes the
# Bluetooth permission request to this tool rather than to your terminal.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building..."
swift build -c release 2>&1 | tail -20

BIN="$(swift build -c release --show-bin-path)/OBDProbe"
APP="dist/OBDProbe.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/OBDProbe"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/OBDProbe"

# Ad-hoc sign so macOS treats it as a stable identity for TCC (Bluetooth) grants.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo ""
exec "$APP/Contents/MacOS/OBDProbe" "$@"
