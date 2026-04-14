#!/bin/bash
# Install Reel from the latest GitHub release.
# Usage: curl -fsSL https://raw.githubusercontent.com/btj93/reel/main/scripts/install.sh | bash
set -euo pipefail

REPO="btj93/reel"
APP_NAME="Reel"
INSTALL_DIR="/Applications"
CLI_NAME="reel-msg"
CLI_LINK="/usr/local/bin/${CLI_NAME}"

echo "Fetching latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)

if [ -z "$TAG" ]; then
    echo "Error: could not find latest release." >&2
    exit 1
fi

echo "Downloading ${APP_NAME} ${TAG}..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -fsSL "https://github.com/${REPO}/releases/download/${TAG}/${APP_NAME}.app.zip" -o "${TMPDIR}/${APP_NAME}.app.zip"

echo "Installing to ${INSTALL_DIR}..."
unzip -qo "${TMPDIR}/${APP_NAME}.app.zip" -d "${TMPDIR}"

if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
    echo "Removing previous installation..."
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

xattr -cr "${TMPDIR}/${APP_NAME}.app"
mv "${TMPDIR}/${APP_NAME}.app" "${INSTALL_DIR}/"

echo "Linking ${CLI_NAME} to ${CLI_LINK}..."
mkdir -p "$(dirname "$CLI_LINK")"
ln -sf "${INSTALL_DIR}/${APP_NAME}.app/Contents/MacOS/${CLI_NAME}" "$CLI_LINK"

echo ""
echo "Installed ${APP_NAME} ${TAG} to ${INSTALL_DIR}/${APP_NAME}.app"
echo "CLI available at: ${CLI_LINK}"
echo ""
echo "To launch: open ${INSTALL_DIR}/${APP_NAME}.app"
echo "macOS will prompt for Accessibility permission on first launch."
