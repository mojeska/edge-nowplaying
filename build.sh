#!/bin/sh
# Builds "Edge Now Playing.app" into build/; with --install, copies it to ~/Applications and opens it.
set -e
cd "$(dirname "$0")"
ARCH="--arch arm64 --arch x86_64"   # universal: Apple Silicon and Intel
swift build -c release $ARCH
APP="build/Edge Now Playing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release $ARCH --show-bin-path)/EdgeNowPlaying" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Signed with a local certificate (see README) so macOS keeps its permissions across rebuilds; ad-hoc if it is missing.
ID="Edge Now Playing Local Signing"
if security find-identity -p codesigning | grep -q "\"$ID\""; then codesign --force --sign "$ID" "$APP"; else codesign --force --sign - "$APP"; fi
echo "Built $APP"
if [ "$1" = "--install" ]; then
  pkill -x EdgeNowPlaying 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Edge Now Playing.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Edge Now Playing.app"
  echo "Installed to ~/Applications and started"
fi
