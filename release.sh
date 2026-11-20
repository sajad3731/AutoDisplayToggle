#!/bin/bash
# Builds a universal (Intel + Apple Silicon) AutoDisplayToggle.app and packs it
# into a zip and a DMG under build/release/, ready to attach to a GitHub release.
#
#   ./release.sh            build, sign, package
#   ./release.sh --publish  also create the GitHub release (needs `gh`)
#
# Signing, picked automatically:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#       Signs with the hardened runtime. Without it the build is ad-hoc signed,
#       and users have to clear the Gatekeeper warning themselves (see README).
#   NOTARY_PROFILE=<name>
#       With DEVELOPER_ID, notarizes and staples both the app and the DMG.
#       Create the profile once with:
#       xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID>
#
# Network:
#   LOCAL_PROXY_URL=http://host:port
#       When set (and HTTPS_PROXY is not), gh talks to GitHub through it.
set -euo pipefail

# Only gh goes through the proxy; the build itself never touches the network.
gh() {
    if [[ -n "${LOCAL_PROXY_URL:-}" && -z "${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
        HTTPS_PROXY="$LOCAL_PROXY_URL" HTTP_PROXY="$LOCAL_PROXY_URL" \
            NO_PROXY="localhost,127.0.0.1,::1" command gh "$@"
    else
        command gh "$@"
    fi
}

cd "$(dirname "$0")"
APP_NAME="AutoDisplayToggle"
BUILD_DIR="build/release"
APP="${BUILD_DIR}/${APP_NAME}.app"
ICON_PNG="Icon/icon.png"
ICON_ICNS="Icon/AppIcon.icns"
MIN_MACOS="14.0"

PUBLISH=0
case "${1:-}" in
    "") ;;
    --publish) PUBLISH=1 ;;
    *) echo "Usage: $0 [--publish]" >&2; exit 2 ;;
esac

plist() { /usr/libexec/PlistBuddy -c "Print :$1" Info.plist; }
VERSION="$(plist CFBundleShortVersionString)"
BUNDLE_ID="$(plist CFBundleIdentifier)"
ZIP="${BUILD_DIR}/${APP_NAME}-${VERSION}.zip"
DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

if [[ "$PUBLISH" == "1" ]]; then
    command -v gh >/dev/null || { echo "--publish needs the GitHub CLI (gh)." >&2; exit 1; }
    # The release tag goes on HEAD, so HEAD has to be exactly what gets built
    # and has to exist on GitHub already.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "Uncommitted changes - commit them first so the tag matches the build." >&2
        exit 1
    fi
    if [[ -z "$(git branch -r --contains HEAD)" ]]; then
        echo "HEAD is not pushed - push it first so GitHub can tag it." >&2
        exit 1
    fi
    if gh release view "v${VERSION}" >/dev/null 2>&1; then
        echo "Release v${VERSION} already exists. Bump CFBundleShortVersionString in Info.plist." >&2
        exit 1
    fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# The SDK ships a .tbd stub for DisplayServices covering both architectures.
# /System/Library/PrivateFrameworks only resolves through this Mac's own
# dyld cache, so it cannot link the other architecture's slice.
SDK="$(xcrun --show-sdk-path)"
build_slice() {
    local arch="$1"
    echo "Building ${arch}..."
    swiftc -O "${APP_NAME}.swift" \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        -sdk "$SDK" \
        -o "${BUILD_DIR}/${APP_NAME}-${arch}" \
        -framework Cocoa \
        -framework UserNotifications \
        -framework Carbon \
        -F "${SDK}/System/Library/PrivateFrameworks" \
        -framework DisplayServices
}
build_slice x86_64
build_slice arm64
lipo -create "${BUILD_DIR}/${APP_NAME}-x86_64" "${BUILD_DIR}/${APP_NAME}-arm64" \
    -output "${BUILD_DIR}/${APP_NAME}"
rm "${BUILD_DIR}/${APP_NAME}-x86_64" "${BUILD_DIR}/${APP_NAME}-arm64"
echo "Universal binary: $(lipo -archs "${BUILD_DIR}/${APP_NAME}")"

echo "Assembling ${APP}..."
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
mv "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"

# Same icon rule as build.sh: a committed .icns wins, else icon.png is
# rendered into every size macOS asks for.
if [[ -f "$ICON_ICNS" ]]; then
    cp "$ICON_ICNS" "${APP}/Contents/Resources/AppIcon.icns"
elif [[ -f "$ICON_PNG" ]]; then
    iconset="${BUILD_DIR}/AppIcon.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -s format png -z "$size" "$size" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}.png" >/dev/null
        sips -s format png -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" \
            --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "${APP}/Contents/Resources/AppIcon.icns"
    rm -rf "$iconset"
else
    echo "No icon found - the app will use the generic icon."
fi

SIGNED_WITH_ID=0
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    # The hardened runtime blocks Apple Events unless entitled; the app sends
    # them through NSAppleScript for "do shell script ... with administrator
    # privileges" (display overrides, the sudoers rule).
    entitlements="${BUILD_DIR}/entitlements.plist"
    cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
</plist>
PLIST
    echo "Signing with '${DEVELOPER_ID}' (hardened runtime)..."
    codesign --force --options runtime --timestamp \
        --entitlements "$entitlements" \
        --identifier "$BUNDLE_ID" \
        --sign "$DEVELOPER_ID" "$APP"
    rm "$entitlements"
    SIGNED_WITH_ID=1
else
    echo "No DEVELOPER_ID set - signing ad-hoc. Users will see a Gatekeeper warning."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

notarize() {
    echo "Notarizing $(basename "$1")..."
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

NOTARIZED=0
if [[ "$SIGNED_WITH_ID" == "1" && -n "${NOTARY_PROFILE:-}" ]]; then
    # notarytool takes a zip, not a bare .app. This one is only for the
    # submission; the zip users get is made after stapling.
    submission="${BUILD_DIR}/notarize.zip"
    ditto -c -k --keepParent "$APP" "$submission"
    notarize "$submission"
    rm "$submission"
    xcrun stapler staple "$APP"
    NOTARIZED=1
fi

echo "Packing ${ZIP}..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Packing ${DMG}..."
staging="${BUILD_DIR}/dmg"
mkdir -p "$staging"
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$staging"

if [[ "$SIGNED_WITH_ID" == "1" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
fi
if [[ "$NOTARIZED" == "1" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

# A Homebrew cask needs the sha256 of whatever it downloads.
(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
echo
cat "${BUILD_DIR}/SHA256SUMS"
echo

if [[ "$PUBLISH" == "1" ]]; then
    if [[ "$NOTARIZED" == "1" ]]; then
        notes="Download the DMG, open it and drag AutoDisplayToggle into Applications."
    else
        notes="Download the DMG, open it and drag AutoDisplayToggle into Applications.

This build is not notarized, so macOS will say it cannot verify the app. Either open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

\`\`\`
xattr -dr com.apple.quarantine /Applications/AutoDisplayToggle.app
\`\`\`"
    fi
    echo "Creating GitHub release v${VERSION}..."
    gh release create "v${VERSION}" "$DMG" "$ZIP" "${BUILD_DIR}/SHA256SUMS" \
        --target "$(git rev-parse HEAD)" \
        --title "${APP_NAME} ${VERSION}" --notes "$notes"
else
    echo "Done. Run './release.sh --publish' to create the GitHub release v${VERSION}."
fi
