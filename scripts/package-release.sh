#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=v1.0
NAME="Scan-$VERSION-macos-arm64"
APP="$PWD/dist/Scan.app"
[[ -d "$APP" && -x dist/bin/scan ]] || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == '1.0.0' ]] || { echo 'Expected app version 1.0.0.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
STAGE="$PWD/.build/release-package/$NAME"
DMG_STAGE="$PWD/.build/release-package/dmg"
rm -rf "$STAGE" "$DMG_STAGE"
mkdir -p "$STAGE/bin" "$DMG_STAGE"
ditto "$APP" "$STAGE/Scan.app"
cp dist/bin/scan "$STAGE/bin/scan"
cp LICENSE "$STAGE/LICENSE"
cp docs/releases/v1.0.md "$STAGE/README.md"
ditto "$APP" "$DMG_STAGE/Scan.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp LICENSE "$DMG_STAGE/LICENSE"
cp docs/releases/v1.0.md "$DMG_STAGE/README.md"
rm -f "dist/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "dist/$NAME.zip"
hdiutil create -volname 'Scan v1.0' -srcfolder "$DMG_STAGE" -format UDZO -ov "dist/$NAME.dmg"
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh "dist/$NAME.dmg" "dist/$NAME.zip" dist/SHA256SUMS.txt
