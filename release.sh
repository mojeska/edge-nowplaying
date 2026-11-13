#!/bin/sh
# Builds the app and zips it for a GitHub release: build/EdgeNowPlaying-<version>.zip
set -e
cd "$(dirname "$0")"
./build.sh
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
rm -f "build/EdgeNowPlaying-$V.zip"
ditto -c -k --keepParent "build/Edge Now Playing.app" "build/EdgeNowPlaying-$V.zip"
echo "build/EdgeNowPlaying-$V.zip"
