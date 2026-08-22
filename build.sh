#!/bin/sh
# Local build. ./build.sh [run|install|test]
set -e
cd "$(dirname "$0")"
APP="build/Xstream.app"

if [ "$1" = "test" ]; then
  # The parser checks don't touch Sparkle, so they compile straight with swiftc.
  mkdir -p build
  swiftc -target "$(uname -m)-apple-macos14.0" -o build/tests Sources/Xtream.swift Tests/main.swift
  exec ./build/tests
fi

swift build -c debug --product Xstream
BIN=$(swift build -c debug --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Xstream" "$APP/Contents/MacOS/Xstream"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/app-icon.icns "$APP/Contents/Resources/app-icon.icns"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Xstream" 2>/dev/null || true
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
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
