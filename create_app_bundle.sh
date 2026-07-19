#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="Wand"
APP_BUNDLE="${APP_NAME}.app"

if [ ! -f "$APP_NAME" ]; then
    echo "Error: $APP_NAME executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

BINARY_NAME="$APP_NAME"

echo "Creating app bundle: $APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "$BINARY_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Copy icon if it exists
if [ -f "Wand.icns" ]; then
    cp "Wand.icns" "${APP_BUNDLE}/Contents/Resources/Wand.icns"
    echo "Icon added to app bundle"
elif [ -f "SiriRemote.icns" ]; then
    cp "SiriRemote.icns" "${APP_BUNDLE}/Contents/Resources/Wand.icns"
    echo "Icon added to app bundle"
fi

# Copy localized strings into the app bundle.
for LPROJ in en.lproj zh-Hans.lproj; do
    if [ -d "$LPROJ" ]; then
        cp -R "$LPROJ" "${APP_BUNDLE}/Contents/Resources/"
    fi
done

# Create proper Info.plist with all required keys
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.wand.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>0.2.0</string>
	<key>CFBundleShortVersionString</key>
	<string>0.2.0</string>
	<key>CFBundleIconFile</key>
	<string>Wand</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Wand Contributors</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Wand needs Bluetooth access to connect to your Siri Remote trackpad.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>Wand needs Bluetooth access to connect to your Siri Remote trackpad.</string>
</dict>
</plist>
EOF

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Sign with hardened runtime + entitlements. Required on modern macOS (14+) for
# IOHIDManager to deliver Bluetooth HID devices like the Siri Remote to the app.
# Ad-hoc (`--sign -`) is used; for distribution, swap in a Developer ID identity.
if [ -f "Wand.entitlements" ]; then
    echo "Signing with hardened runtime + entitlements..."
    codesign --force --options=runtime \
        --entitlements "Wand.entitlements" \
        --sign - \
        "${APP_BUNDLE}"
    codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(flags|Identifier)" || true
else
    # Signing is not optional — without the bluetooth entitlement, IOHIDManager won't
    # deliver the Siri Remote on macOS 14+. Fail loudly instead of shipping a broken app.
    echo "ERROR: Wand.entitlements not found — cannot sign. Aborting." >&2
    exit 1
fi

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "You can now:"
echo "  1. Double-click $APP_BUNDLE to run it"
echo "  2. Or run: open $APP_BUNDLE"
echo ""
echo "Note: You'll need to grant Accessibility permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
