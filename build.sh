#!/bin/bash
# Builds AutoDisplayToggle and, with --install, packages it into /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AutoDisplayToggle"
BUILD_DIR="build"
APP_BUNDLE="/Applications/${APP_NAME}.app"
ICON_PNG="Icon/icon.png"
SIGN_IDENTITY_NAME="${CODESIGN_IDENTITY:-AutoDisplayToggle Dev}"
ICON_ICNS="Icon/AppIcon.icns"
BUILT_ICNS="${BUILD_DIR}/AppIcon.icns"

mkdir -p "$BUILD_DIR"

echo "Building ${APP_NAME}..."
swiftc -O "${APP_NAME}.swift" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    -framework Cocoa \
    -framework UserNotifications \
    -framework Carbon

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
        # Called as `build_icon && ...`, where set -e does not apply, so every
        # failure has to return by itself.
        sips -s format png -z "$size" "$size" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}.png" >/dev/null || return 1
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null || return 1
    done
    iconutil -c icns "$iconset" -o "$BUILT_ICNS" || return 1
    echo "Built ${BUILT_ICNS} from ${ICON_PNG}"
}

HAVE_ICON=0
build_icon && HAVE_ICON=1
if [[ "$HAVE_ICON" != "1" && -f "$ICON_PNG" ]]; then
    echo "Warning: could not build the icon from ${ICON_PNG}; the app will use the generic icon."
fi

if [[ "${1:-}" != "--install" ]]; then
    echo "Run './build.sh --install' to install into /Applications."
    exit 0
fi

# Stop the running instance. Its termination handler re-enables the
# internal display, so this will not leave the panel dark. Only the app
# itself: its command line is the bare executable path, while its helpers
# carry arguments (the panel watchdog finishes on its own once the app is
# gone).
APP_PROCESS="^${APP_BUNDLE}/Contents/MacOS/${APP_NAME}\$"
if pgrep -f "$APP_PROCESS" >/dev/null 2>&1; then
    echo "Stopping running instance..."
    pkill -f "$APP_PROCESS" || true
    for _ in $(seq 1 20); do
        pgrep -f "$APP_PROCESS" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi

echo "Installing to ${APP_BUNDLE}..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"
# Removed first, so a helper still running the old binary keeps its own copy
# instead of having the file rewritten under it.
rm -f "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
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

# macOS ties the notification grant to the code signing identity. An ad-hoc
# signature (--sign -) is just a hash of the binary, so every rebuild looks
# like a different app and the grant is dropped. A self-signed certificate
# stays the same across rebuilds, so the grant sticks. See README.
# Read in full before matching: grep -q leaves at the first match, and with
# pipefail a writer cut off mid-output would fail the whole test.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -qF "${SIGN_IDENTITY_NAME}" <<< "$IDENTITIES"; then
    echo "Signing with '${SIGN_IDENTITY_NAME}'..."
    codesign --force --sign "${SIGN_IDENTITY_NAME}" \
        --identifier com.user.AutoDisplayToggle "${APP_BUNDLE}" \
        || echo "Warning: signing failed."
else
    codesign --force --sign - --identifier com.user.AutoDisplayToggle \
        "${APP_BUNDLE}" >/dev/null 2>&1 \
        || echo "Warning: ad-hoc signing failed; notifications may fall back to osascript."
    echo "Signed ad-hoc. Notification permission will have to be re-granted after"
    echo "every rebuild - see 'Making permissions stick' in README.md."
fi

# Nudge Finder/Dock to drop the cached icon for this bundle.
touch "${APP_BUNDLE}"

echo "Launching..."
open -a "${APP_BUNDLE}"
echo "Done."
