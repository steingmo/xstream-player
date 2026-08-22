#!/bin/sh
set -e
cd "$(dirname "$0")"
APP="build/Xstream.app"
TARGET="$(uname -m)-apple-macos14.0"

if [ "$1" = "test" ]; then
  mkdir -p build
  swiftc -target "$TARGET" -o build/tests Sources/Xtream.swift Tests/main.swift
  exec ./build/tests
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/app-icon.icns "$APP/Contents/Resources/app-icon.icns"
swiftc -O -parse-as-library -target "$TARGET" -framework AVKit -framework AVFoundation -o "$APP/Contents/MacOS/Xstream" Sources/*.swift
codesign --force --sign - "$APP"
echo "built $APP"

case "$1" in
  run) open "$APP" ;;
  # ditto rather than cp: it preserves the bundle's metadata, so the signature survives.
  install)
    rm -rf /Applications/Xstream.app
    ditto "$APP" /Applications/Xstream.app
    echo "installed /Applications/Xstream.app"
    ;;
esac
exit 0
