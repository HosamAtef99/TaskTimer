#!/bin/bash
# Installs (or reinstalls) the latest TaskTimer Dev (Hosam's test copy):
#   curl -fsSL https://raw.githubusercontent.com/HosamAtef99/TaskTimer/main/install.sh | bash
# It installs as "TaskTimer Dev.app" and never touches the team's TaskTimer.app.
set -e
REPO="HosamAtef99/TaskTimer"
APP_NAME="TaskTimer Dev"
EXE="TaskTimerDev"
BUNDLE_ID="com.hosam.tasktimer.dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Downloading the latest $APP_NAME…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/TaskTimer.app.zip" -o "$TMP/TaskTimer.app.zip"
ditto -x -k "$TMP/TaskTimer.app.zip" "$TMP"

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -x "$EXE" >/dev/null 2>&1 || break; sleep 0.5; done

rm -rf "$DEST/$APP_NAME.app"
ditto "$TMP/TaskTimer.app" "$DEST/$APP_NAME.app"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true

echo "▸ Installed to $DEST — opening $APP_NAME"
open "$DEST/$APP_NAME.app"
