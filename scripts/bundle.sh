#!/bin/bash
# Manual app bundling script (backup for swift-bundler)
set -euo pipefail

PRODUCT="Reel"
CONFIG="${1:-debug}"
BUILD_DIR=".build/${CONFIG}"
BUNDLE_DIR=".build/bundled/${PRODUCT}.app"

echo "Building ${PRODUCT} (${CONFIG})..."
swift build -c "${CONFIG}"

# Create bundle structure only if it doesn't exist yet.
# DON'T rm -rf — that revokes macOS Accessibility permission.
if [ ! -d "${BUNDLE_DIR}/Contents/MacOS" ]; then
    echo "Creating app bundle..."
    mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
    mkdir -p "${BUNDLE_DIR}/Contents/Resources"

    cat > "${BUNDLE_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.reel.Reel</string>
    <key>CFBundleName</key>
    <string>Reel</string>
    <key>CFBundleDisplayName</key>
    <string>Reel</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Reel</string>
    <key>CFBundleIconFile</key>
    <string>Reel</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
fi

# Only replace the binary — preserves macOS permissions on the .app bundle
cp "${BUILD_DIR}/${PRODUCT}" "${BUNDLE_DIR}/Contents/MacOS/"

# Copy icon
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SRC="${SCRIPT_DIR}/../Resources/Reel.icns"
if [ -f "${ICON_SRC}" ]; then
    cp "${ICON_SRC}" "${BUNDLE_DIR}/Contents/Resources/"
fi

# Ad-hoc code sign with a stable identifier.
# macOS TCC tracks permissions by code signature hash — without signing,
# every rebuild produces a different hash and macOS revokes permission.
# Ad-hoc signing (-s -) with a fixed identifier keeps it stable.
codesign -fs - --identifier "dev.reel.Reel" "${BUNDLE_DIR}"

echo "Bundle updated at: ${BUNDLE_DIR}"
echo "Run with: open ${BUNDLE_DIR}"
