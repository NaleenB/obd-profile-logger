#!/bin/bash
# Archives the phone's recorded sessions into sessions/.
#
# Reading device logs out of a throwaway temp directory loses them when the
# machine is cleaned up, and an interrupted session is only complete after a
# later pull. So every pull lands in the project archive first; analysis and
# export read from here.
#
# Usage: tools/pull-ios-sessions.sh [udid]
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-${OBD_DEVICE:-00008130-00080DE82692001C}}"
BUNDLE_ID="com.naleen.obdlogger"
REMOTE="Library/Application Support/OBDLogger/Sessions"
ARCHIVE="sessions"

mkdir -p "$ARCHIVE"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/obd-sessions.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "Device: $DEVICE"
if ! xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source "$REMOTE" \
  --destination "$STAGE" >"$STAGE/.copy.log" 2>&1; then
  tail -20 "$STAGE/.copy.log" >&2
  exit 1
fi
grep -viE "post-quantum|store now|^[[:space:]]*$" "$STAGE/.copy.log" | tail -3 || true

if [ -z "$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]; then
  echo "No sessions returned from the device." >&2
  exit 1
fi

NEW=0
REFRESHED=0
for src in "$STAGE"/*/; do
  id="$(basename "$src")"
  dst="$ARCHIVE/$id"
  if [ -d "$dst" ]; then
    # Merge, don't replace: the phone's copy is append-only and may have grown.
    rsync -a "$src" "$dst/"
    REFRESHED=$((REFRESHED + 1))
  else
    cp -R "$src" "$dst"
    NEW=$((NEW + 1))
  fi
  printf '  %s\n' "$id"
done

STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "$STAMP" >"$ARCHIVE/.last-pull"
printf '%s %s %s new %s refreshed\n' "$STAMP" "$DEVICE" "$NEW" "$REFRESHED" >>"$ARCHIVE/.pull-log"

echo "Archived $NEW new, $REFRESHED refreshed in $ARCHIVE/"
