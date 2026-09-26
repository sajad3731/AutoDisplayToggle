#!/bin/bash
# Builds AutoDisplayToggle and, with --install, packages it into /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AutoDisplayToggle"
BUILD_DIR="build"
APP_BUNDLE="/Applications/${APP_NAME}.app"

mkdir -p "$BUILD_DIR"

echo "Building ${APP_NAME}..."
swiftc -O "${APP_NAME}.swift" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    -framework Cocoa \
    -F /System/Library/PrivateFrameworks \
    -framework DisplayServices

echo "Built ${BUILD_DIR}/${APP_NAME}"

if [[ "${1:-}" != "--install" ]]; then
    echo "Run './build.sh --install' to install into /Applications."
    exit 0
fi

# Stop the running instance. Its termination handler re-enables the
# internal display, so this will not leave the panel dark.
if pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1; then
    echo "Stopping running instance..."
    pkill -f "${APP_BUNDLE}" || true
    sleep 2
fi

echo "Installing to ${APP_BUNDLE}..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "Launching..."
open -a "${APP_BUNDLE}"
echo "Done."
