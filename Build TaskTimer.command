#!/bin/bash
# Builds TaskTimer.app from the source in this folder and installs it to Applications.
# Double-click it. The first time, macOS may ask to install the Command Line Tools.
# TaskTimer also runs this script itself (with TT_UPDATE=1) when you press Update.

cd "$(dirname "$0")" || exit 1
set -e

# Hosam's dev copy: its own name, executable and bundle ID, so it installs
# next to the team's TaskTimer instead of replacing it.
APP_NAME="TaskTimer Dev"
EXE="TaskTimerDev"
BUNDLE_ID="com.hosam.tasktimer.dev"

say() { printf "\n\033[1;35m▸ %s\033[0m\n" "$1"; }
fail() {
  printf "\n\033[1;31m✗ %s\033[0m\n" "$1"
  if [ -n "$TT_UPDATE" ]; then
    echo "TT_BUILD_FAILED"
  else
    read -r -p "Press Return to close…"
  fi
  exit 1
}

VERSION="$(tr -d ' \n\r' < Resources/VERSION 2>/dev/null || echo 1.0)"
say "TaskTimer Dev $VERSION"

say "Checking the Swift compiler"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  [ -z "$TT_UPDATE" ] && { xcode-select --install >/dev/null 2>&1 || true; }
  fail "Apple's Command Line Tools aren't installed. A window just opened to install them — finish it, then double-click this file again."
fi

# If full Xcode is installed, use it (it ships SwiftUI's macro plugins).
for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  if [ -d "$X" ] && DEVELOPER_DIR="$X/Contents/Developer" xcrun --find swiftc >/dev/null 2>&1; then
    export DEVELOPER_DIR="$X/Contents/Developer"; echo "Using $X"; break
  fi
done
xcrun swiftc --version 2>&1 | head -1

# Pass any macro plugin folders that exist.
PLUGIN_ARGS=()
for d in "$(xcrun --show-sdk-platform-path 2>/dev/null)/Developer/usr/lib/swift/host/plugins" \
         "$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins"; do
  [ -d "$d" ] && PLUGIN_ARGS+=(-plugin-path "$d")
done

ARCH="$(uname -m)"
OUT="build/TaskTimer.app"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

compile() {  # $1 = arch, $2 = output binary
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$1-apple-macos13.0" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
    Sources/*.swift -o "$2" 2>> build_errors.txt
}

rm -f build_errors.txt
if [ -n "$TT_CI" ]; then
  # GitHub build: one app that runs on both Apple Silicon and Intel Macs.
  say "Compiling (arm64 + x86_64)"
  if compile arm64 build/tt-arm64 && compile x86_64 build/tt-x86_64; then
    lipo -create build/tt-arm64 build/tt-x86_64 -output "$OUT/Contents/MacOS/$EXE"
    rm -f build/tt-arm64 build/tt-x86_64
  else
    cat build_errors.txt
    # Show each compiler error as an annotation on the GitHub run.
    grep -E '^[^ ]+\.swift:[0-9]+:[0-9]+: error:' build_errors.txt | sort -u | \
      sed -E 's/^([^:]+):([0-9]+):([0-9]+): error: (.*)$/::error file=\1,line=\2,col=\3::\4/' || true
    fail "Build failed."
  fi
else
  say "Compiling ($ARCH)"
  if ! compile "$ARCH" "$OUT/Contents/MacOS/$EXE"; then
    cat build_errors.txt
    fail "Build failed. Send build_errors.txt (in this folder) to Claude."
  fi
fi
rm -f build_errors.txt

say "Packing the app"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$OUT/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"
# The Chrome extension ships inside the app; TaskTimer copies it into place on launch.
cp -R ChromeExtension "$OUT/Contents/Resources/ChromeExtension"
# After Effects helper (signed in CI before this step; a local build ships it unsigned)
cp -R AEHelper "$OUT/Contents/Resources/AEHelper"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || true

if [ -n "$TT_CI" ]; then
  ditto -c -k --keepParent "$OUT" build/TaskTimer.app.zip
  cp Resources/VERSION build/VERSION
  say "Built build/TaskTimer.app.zip ($VERSION)"
  exit 0
fi

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

say "Installing to $DEST"
if [ -n "$TT_UPDATE" ]; then
  # TaskTimer already saved everything before starting the update.
  pkill -TERM -x "$EXE" >/dev/null 2>&1 || true
else
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
fi
# Wait until the old copy has really quit before replacing it.
for _ in $(seq 1 30); do
  pgrep -x "$EXE" >/dev/null 2>&1 || break
  sleep 0.5
done
rm -rf "$DEST/$APP_NAME.app"
cp -R "$OUT" "$DEST/$APP_NAME.app"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true

say "Done — opening $APP_NAME $VERSION"
open "$DEST/$APP_NAME.app"
echo "TT_BUILD_OK"
