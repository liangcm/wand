#!/bin/bash

# Packages Wand.app into a distributable, drag-to-install DMG, signed with a
# Developer ID certificate when one is available (falls back to ad-hoc).
# Uses only tools shipped with macOS (iconutil + hdiutil + codesign).
#
# Usage:
#   ./create_dmg.sh                                # build + bundle + sign + package
#   VERSION=1.2 ./create_dmg.sh
#   SIGN_IDENTITY="Developer ID Application: ..." ./create_dmg.sh   # explicit identity
#   NOTARY_PROFILE=wand-notary ./create_dmg.sh     # + notarize & staple (full release)
#
# The full chain is: build.sh -> create_app_bundle.sh -> re-sign -> DMG -> sign DMG
# -> (with NOTARY_PROFILE) notarize -> staple.
#
# NOTARY_PROFILE is a notarytool keychain profile, created once via:
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>

set -e

APP_NAME="Wand"
APP_BUNDLE="${APP_NAME}.app"
VERSION="${VERSION:-0.1}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
VOL_NAME="${APP_NAME} ${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 0. Pick the signing identity: explicit override > Developer ID in keychain > ad-hoc.
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing identity: $SIGN_IDENTITY"
else
    SIGN_IDENTITY="-"
    echo "⚠️  No Developer ID certificate found — falling back to ad-hoc signing."
    echo "    The DMG will work on this Mac but other Macs will refuse to open the app."
fi

# 1. Generate the .icns from the iconset so the bundled app carries its icon.
if [ -d "${APP_NAME}.iconset" ]; then
    echo "Generating ${APP_NAME}.icns from ${APP_NAME}.iconset..."
    iconutil -c icns "${APP_NAME}.iconset" -o "${APP_NAME}.icns"
fi

# 2. Build the binary if it isn't there yet.
if [ ! -f "$APP_NAME" ]; then
    echo "Binary not found — running build.sh..."
    ./build.sh
fi

# 3. (Re)create the app bundle so it picks up the freshest binary + icon.
#    (create_app_bundle.sh ad-hoc signs; we re-sign below for distribution.)
echo "Creating app bundle..."
./create_app_bundle.sh

# 4. Re-sign the app for distribution: hardened runtime + entitlements + secure
#    timestamp (required for notarization). --force replaces the ad-hoc signature.
echo "Signing ${APP_BUNDLE}..."
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --options=runtime --entitlements "${APP_NAME}.entitlements" \
        --sign - "$APP_BUNDLE"
else
    codesign --force --options=runtime --entitlements "${APP_NAME}.entitlements" \
        --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --strict --deep "$APP_BUNDLE"
echo "Signature:"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "Authority=|Identifier=|flags" | head -5

# 5. Stage the DMG contents: the app plus a shortcut to /Applications so the
#    user can drag-to-install.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# 6. Build a compressed (UDZO) DMG.
echo "Building ${DMG_NAME}..."
rm -f "$DMG_NAME"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_NAME" >/dev/null

# 7. Sign the DMG itself so the download is attributable end-to-end.
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Signing ${DMG_NAME}..."
    codesign --timestamp --sign "$SIGN_IDENTITY" "$DMG_NAME"
    codesign --verify "$DMG_NAME"
fi

# 8. Notarize + staple when a notary profile is provided — after this, other Macs
#    open the app with no Gatekeeper warning, even offline (the ticket is stapled).
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Submitting to Apple notary service (typically 1-5 minutes)..."
    xcrun notarytool submit "$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_NAME"
    spctl -a -t open --context context:primary-signature "$DMG_NAME" \
        && echo "✓ Notarized & stapled — Gatekeeper accepts this DMG"
fi

echo ""
echo "✓ Created $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
echo ""
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$NOTARY_PROFILE" ]; then
    echo "Signed but NOT notarized — other Macs will warn. For a release build:"
    echo "    NOTARY_PROFILE=<profile> ./create_dmg.sh"
fi
echo "To install: open the DMG and drag ${APP_BUNDLE} onto the Applications folder."
