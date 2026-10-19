#!/bin/bash
# Installs (or reinstalls) the latest TaskTimer:
#   curl -fsSL https://raw.githubusercontent.com/mo-animation/TaskTimer/main/install.sh | bash
set -e
REPO="mo-animation/TaskTimer"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Downloading the latest TaskTimer…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/TaskTimer.app.zip" -o "$TMP/TaskTimer.app.zip"
ditto -x -k "$TMP/TaskTimer.app.zip" "$TMP"

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

osascript -e 'tell application "TaskTimer" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -x TaskTimer >/dev/null 2>&1 || break; sleep 0.5; done

rm -rf "$DEST/TaskTimer.app"
ditto "$TMP/TaskTimer.app" "$DEST/TaskTimer.app"
xattr -dr com.apple.quarantine "$DEST/TaskTimer.app" 2>/dev/null || true

echo "▸ Installed to $DEST — opening TaskTimer"
open "$DEST/TaskTimer.app"
