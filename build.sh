#!/bin/sh
# Builds "Edge Now Playing.app" into build/; with --install, copies it to ~/Applications and opens it.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Edge Now Playing.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/EdgeNowPlaying" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "$1" = "--install" ]; then
  pkill -x EdgeNowPlaying 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Edge Now Playing.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Edge Now Playing.app"
  echo "Installed to ~/Applications and started"
fi
