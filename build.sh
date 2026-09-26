#!/bin/bash
# Builds AutoDisplayToggle and, with --install, packages it into /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AutoDisplayToggle"
BUILD_DIR="build"
APP_BUNDLE="/Applications/${APP_NAME}.app"
ICON_PNG="Icon/icon.png"
ICON_ICNS="Icon/AppIcon.icns"
BUILT_ICNS="${BUILD_DIR}/AppIcon.icns"

mkdir -p "$BUILD_DIR"

echo "Building ${APP_NAME}..."
swiftc -O "${APP_NAME}.swift" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    -framework Cocoa \
    -framework UserNotifications \
    -F /System/Library/PrivateFrameworks \
    -framework DisplayServices

echo "Built ${BUILD_DIR}/${APP_NAME}"

# A committed .icns wins; otherwise Icon/icon.png is converted into every size
# macOS asks for (Finder, Dock, notifications, System Settings all pick
# different ones, so a single-size icon looks blurry in half of them).
build_icon() {
    if [[ -f "$ICON_ICNS" ]]; then
        cp "$ICON_ICNS" "$BUILT_ICNS"
        echo "Using ${ICON_ICNS}"
        return 0
    fi

    if [[ ! -f "$ICON_PNG" ]]; then
        echo "No ${ICON_PNG} or ${ICON_ICNS} found - the app will use the generic icon."
        return 1
    fi

    local iconset="${BUILD_DIR}/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}.png" >/dev/null
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$BUILT_ICNS"
    echo "Built ${BUILT_ICNS} from ${ICON_PNG}"
}

HAVE_ICON=0
build_icon && HAVE_ICON=1

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
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [[ "$HAVE_ICON" == "1" ]]; then
    cp "$BUILT_ICNS" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    # An icon pasted onto the bundle in Finder is stored as a custom-icon
    # resource that overrides Contents/Resources, so it has to go or the
    # bundled icon never shows up.
    rm -f "${APP_BUNDLE}/$(printf 'Icon\r')"
    xattr -d com.apple.FinderInfo "${APP_BUNDLE}" >/dev/null 2>&1 || true
fi

# Ad-hoc signature. Notifications are delivered under the bundle identity, and
# an unsigned bundle is where that tends to be refused.
codesign --force --sign - --identifier com.user.AutoDisplayToggle \
    "${APP_BUNDLE}" >/dev/null 2>&1 \
    || echo "Warning: ad-hoc signing failed; notifications may fall back to osascript."

# Nudge Finder/Dock to drop the cached icon for this bundle.
touch "${APP_BUNDLE}"

echo "Launching..."
open -a "${APP_BUNDLE}"
echo "Done."
