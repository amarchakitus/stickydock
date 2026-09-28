#!/bin/zsh
# Usage:
#   ./build.sh           build build/StickyDock.app (universal: arm64 + x86_64)
#   ./build.sh install   build and copy to /Applications
#   ./build.sh release   build and package build/StickyDock-<version>.zip and .dmg
#
# Signing: uses the "StickyDock Local Signing" certificate from your keychain
# (see scripts/make_cert.sh), so macOS keeps the Accessibility permission across
# rebuilds. SIGN_KEYCHAIN points at a specific unlocked keychain instead (used by CI).
# Without a certificate, builds are ad-hoc signed, except release builds, which fail.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/StickyDock.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
IDENTITY="StickyDock Local Signing"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Info.plist "$APP/Contents/Info.plist"

rm -rf build/AppIcon.iconset
swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        Sources/*.swift -o "build/obj/StickyDock-$arch"
done
lipo -create build/obj/StickyDock-arm64 build/obj/StickyDock-x86_64 \
    -output "$APP/Contents/MacOS/StickyDock"

has_identity() {
    security find-identity -p codesigning "$@" 2>/dev/null | grep -q "\"$IDENTITY\""
}

# --options runtime: hardened runtime, so other code can't be injected into the
# process (e.g. via DYLD_INSERT_LIBRARIES) to borrow its Accessibility permission.
SIGN=(codesign --force --options runtime --identifier "$BUNDLE_ID")
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    has_identity "$SIGN_KEYCHAIN" || { echo "error: no \"$IDENTITY\" in $SIGN_KEYCHAIN" >&2; exit 1; }
    "${SIGN[@]}" --keychain "$SIGN_KEYCHAIN" --sign "$IDENTITY" "$APP"
elif has_identity; then
    "${SIGN[@]}" --sign "$IDENTITY" "$APP"
elif [[ "$MODE" == "release" ]]; then
    echo "error: release builds must be signed; run scripts/make_cert.sh first" >&2
    exit 1
else
    echo "warning: no signing certificate; ad-hoc signing (run scripts/make_cert.sh once to fix)"
    "${SIGN[@]}" --sign - "$APP"
fi
echo "Built $APP ($VERSION)"

case "$MODE" in
    install)
        pkill -x StickyDock 2>/dev/null || true
        rm -rf /Applications/StickyDock.app
        cp -R "$APP" /Applications/
        echo "Installed to /Applications/StickyDock.app"
        ;;
    release)
        ZIP="build/StickyDock-$VERSION.zip"
        DMG="build/StickyDock-$VERSION.dmg"
        rm -f "$ZIP" "$DMG"
        ditto -c -k --keepParent "$APP" "$ZIP"

        STAGE=build/dmg
        rm -rf "$STAGE"
        mkdir -p "$STAGE"
        cp -R "$APP" "$STAGE/"
        ln -s /Applications "$STAGE/Applications"
        hdiutil create -volname "StickyDock $VERSION" -srcfolder "$STAGE" \
            -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
        rm -rf "$STAGE"
        (cd build && shasum -a 256 "${ZIP:t}" "${DMG:t}" > SHA256SUMS)
        echo "Packaged $ZIP, $DMG and build/SHA256SUMS"
        ;;
esac
