#!/bin/bash
# Build and launch the macOS app. No Xcode UI, no signing setup.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
fi

echo "Generating project…"
xcodegen generate >/dev/null

echo "Building…"
xcodebuild \
  -project OBDLogger.xcodeproj \
  -scheme OBDLogger-macOS \
  -configuration Debug \
  -derivedDataPath build \
  build 2>&1 | grep -E "error:|warning: .*deprecated|BUILD" | tail -5

APP="build/Build/Products/Debug/OBDLogger-macOS.app"
if [ ! -d "$APP" ]; then
  echo "Build produced no app at $APP" >&2
  exit 1
fi

echo "Launching $APP"
open "$APP"
