#!/bin/zsh
# Builds a signed, notarized, universal Xstream.app and the Sparkle appcast.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials:
#        xcrun notarytool store-credentials xstream-notary \
#          --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#      Defaults to the shared keytype-notary profile these apps already use.
#   3. The Sparkle EdDSA private key in the keychain — the same one the other apps use,
#      matching SUPublicEDKey in Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${XSTREAM_IDENTITY:-Developer ID Application}"
PROFILE="${XSTREAM_NOTARY_PROFILE:-keytype-notary}"
APP=build/Xstream.app
ZIP=build/Xstream.zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
# Sparkle compares sparkle:version against the installed app's CFBundleVersion, so the
# feed has to advertise the build number, not the marketing string.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)

echo "==> Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product Xstream
# Asked, not hard-coded: Swift 6.4 moved universal builds from .build/apple to .build/out.
BIN=$(swift build -c release --arch arm64 --arch x86_64 --product Xstream --show-bin-path)

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Xstream" "$APP/Contents/MacOS/Xstream"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/app-icon.icns "$APP/Contents/Resources/app-icon.icns"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Xstream" 2>/dev/null || true
xattr -cr "$APP"

echo "==> Signing with '${IDENTITY}' (hardened runtime)"
# Sparkle's nested helpers must each carry their own hardened-runtime signature.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1) — first launch will warn"
else
    echo "==> Notarizing (profile: ${PROFILE})"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "==> Generating appcast.xml"
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$ZIP" | tr -d '\n')
PUBDATE=$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")
cat > appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Xstream</title>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/steingmo/xstream-player/releases/download/v${VERSION}/Xstream.zip"
        ${SIGNATURE}
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

echo ""
echo "Done: ${ZIP} (macOS 14+, universal)."
echo "Publish in this order — the appcast advertises the release URL, so the release"
echo "has to exist before the feed points anyone at it:"
echo "  1. gh release create v${VERSION} ${ZIP} --title \"Xstream ${VERSION}\" --notes \"...\""
echo "  2. git add appcast.xml && git commit -m \"Xstream ${VERSION}\" && git push"
echo "  3. /opt/homebrew/Library/Taps/steingmo/homebrew-tap/bump-cask.sh xstream-player ${VERSION}"
spctl --assess --type execute --verbose "$APP" || true
