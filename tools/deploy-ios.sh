#!/bin/bash
# Builds and installs the iOS app, incrementing the patch version first.
#
# One command per deploy, and the version on screen is always the one that was
# just installed. Keeping the bump here rather than in a hand-edited field is the
# point: a version nobody remembers to change is worse than no version.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="App/project.yml"
DEVICE="${OBD_DEVICE:-00008130-00080DE82692001C}"
TEAM="${OBD_TEAM:-BD6XNS3GBZ}"

CURRENT="$(grep -m1 'MARKETING_VERSION:' "$PROJECT" | sed 's/.*"\(.*\)".*/\1/')"
if [ -z "$CURRENT" ]; then
  echo "Could not read MARKETING_VERSION from $PROJECT" >&2
  exit 1
fi

MAJOR="$(echo "$CURRENT" | cut -d. -f1)"
MINOR="$(echo "$CURRENT" | cut -d. -f2)"
PATCH="$(echo "$CURRENT" | cut -d. -f3)"
NEXT="$MAJOR.$MINOR.$((PATCH + 1))"

sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$NEXT\"/" "$PROJECT"
echo "Version: $CURRENT -> $NEXT"

cd App
xcodegen generate >/dev/null

xcodebuild \
  -project OBDLogger.xcodeproj \
  -scheme OBDLogger-iOS \
  -destination "id=$DEVICE" \
  -configuration Debug \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  -derivedDataPath /tmp/obd-device-dd \
  build 2>&1 | grep -E "error:|BUILD" | tail -3

APP="/tmp/obd-device-dd/Build/Products/Debug-iphoneos/OBDLogger-iOS.app"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 \
  | grep -viE "post-quantum|store now" | grep -E "bundleID|error" | head -2

echo "Installed $NEXT on $DEVICE"
