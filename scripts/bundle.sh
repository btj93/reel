#!/bin/bash
# Manual app bundling script (backup for swift-bundler)
set -euo pipefail

PRODUCT="Reel"
CONFIG="${1:-debug}"
BUILD_DIR=".build/${CONFIG}"
BUNDLE_DIR=".build/bundled/${PRODUCT}.app"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(grep -o '"[0-9][0-9.]*"' "${SCRIPT_DIR}/../.release-please-manifest.json" | tr -d '"')

echo "Building ${PRODUCT} ${VERSION} (${CONFIG})..."
swift build -c "${CONFIG}"

# Create bundle structure only if it doesn't exist yet.
# DON'T rm -rf — that revokes macOS Accessibility permission.
if [ ! -d "${BUNDLE_DIR}/Contents/MacOS" ]; then
    echo "Creating app bundle..."
    mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
    mkdir -p "${BUNDLE_DIR}/Contents/Resources"
fi

# Always rewrite Info.plist so the version stays current.
cat > "${BUNDLE_DIR}/Contents/Info.plist" << PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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

# Only replace the binary — preserves macOS permissions on the .app bundle
cp "${BUILD_DIR}/${PRODUCT}" "${BUNDLE_DIR}/Contents/MacOS/"

# Copy SwiftPM resource bundle into the .app.
# Place in Contents/Resources/ (standard .app location). The Config module's
# resourceBundle accessor checks both this path and SwiftPM's default path.
CONFIG_BUNDLE="${BUNDLE_DIR}/Contents/Resources/Reel_Config.bundle"
mkdir -p "${CONFIG_BUNDLE}"
cp "${SCRIPT_DIR}/../Sources/Config/config.default.toml" "${CONFIG_BUNDLE}/"

# Copy icon
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
