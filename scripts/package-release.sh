#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Scan.app"
[[ -d "$APP" && -x dist/bin/scan ]] || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
VERSION="${1:-v$APP_VERSION}"
[[ "${VERSION#v}" == "$APP_VERSION" ]] || { echo "Expected app version ${VERSION#v}, found $APP_VERSION." >&2; exit 1; }
NOTES="docs/releases/$VERSION.md"
[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES" >&2; exit 1; }
NAME="Scan-$VERSION-macos-arm64"
codesign --verify --deep --strict "$APP"
STAGE="$PWD/.build/release-package/$NAME"
DMG_STAGE="$PWD/.build/release-package/dmg"
rm -rf "$STAGE" "$DMG_STAGE"
mkdir -p "$STAGE/bin" "$DMG_STAGE"
ditto "$APP" "$STAGE/Scan.app"
cp dist/bin/scan "$STAGE/bin/scan"
cp LICENSE "$STAGE/LICENSE"
cp "$NOTES" "$STAGE/README.md"
ditto "$APP" "$DMG_STAGE/Scan.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp LICENSE "$DMG_STAGE/LICENSE"
cp "$NOTES" "$DMG_STAGE/README.md"
rm -f "dist/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "dist/$NAME.zip"
hdiutil create -volname "Scan $VERSION" -srcfolder "$DMG_STAGE" -format UDZO -ov "dist/$NAME.dmg"
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh "dist/$NAME.dmg" "dist/$NAME.zip" dist/SHA256SUMS.txt
