#!/bin/zsh
# Builds a signed, notarized, universal Xstream.app ready to distribute.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials:
#        xcrun notarytool store-credentials xstream-notary \
#          --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#      Defaults to the shared keytype-notary profile these apps already use.
#      Already have a profile from another app? Point at it instead:
#        XSTREAM_NOTARY_PROFILE=kvf-notary ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${XSTREAM_IDENTITY:-Developer ID Application}"
PROFILE="${XSTREAM_NOTARY_PROFILE:-keytype-notary}"
APP=build/Xstream.app
ZIP=build/Xstream.zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

echo "==> Building universal binary (arm64 + x86_64)"
rm -rf build/universal "$APP" "$ZIP"
mkdir -p build/universal "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$arch-apple-macos14.0" \
        -framework AVKit -framework AVFoundation \
        -o "build/universal/Xstream-$arch" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Xstream" \
    build/universal/Xstream-arm64 build/universal/Xstream-x86_64
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/app-icon.icns "$APP/Contents/Resources/app-icon.icns"
xattr -cr "$APP"

echo "==> Signing with '${IDENTITY}' (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"

# SKIP_NOTARIZE=1 produces a signed-but-unnotarized zip: installable, but Gatekeeper
# warns on first launch. Only useful when no notary profile is set up yet.
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

echo ""
echo "Done: ${ZIP} (macOS 14+, universal)."
echo "Publish:"
echo "  1. gh release create v${VERSION} ${ZIP} --title \"Xstream ${VERSION}\" --notes \"...\""
echo "  2. /opt/homebrew/Library/Taps/steingmo/homebrew-tap/bump-cask.sh xstream-player ${VERSION}"
spctl --assess --type execute --verbose "$APP" || true
