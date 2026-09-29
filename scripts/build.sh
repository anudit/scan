#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ ! -f Vendor/DuckDB/libduckdb_static.a ]]; then scripts/bootstrap.sh; fi
if [[ ! -f Vendor/DuckDB/libduckdb_shared.dylib ]]; then scripts/build-duckdb-dylib.sh; fi
xcodebuild -project Scan.xcodeproj -scheme ScanDesktop -configuration Release \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build >/tmp/scan-xcode-build.log
APP="$PWD/dist/Scan.app"
rm -rf "$APP"
mkdir -p "$PWD/dist/bin"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILT_APP="$PWD/.build/xcode/Build/Products/Release/Scan.app"
ditto "$BUILT_APP" "$APP"
# The unsigned build product carries the same Quick Look extension id; if LaunchServices
# keeps it registered, Quick Look can resolve to it and silently skip the dist copy.
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
rm -rf "$BUILT_APP"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Vendor/DuckDB/libduckdb_shared.dylib "$APP/Contents/Frameworks/libduckdb_shared.dylib"
cp Vendor/DuckDB/LICENSE "$APP/Contents/Resources/DuckDB-LICENSE"
codesign --force --sign - "$APP/Contents/Frameworks/libduckdb_shared.dylib"
codesign --force --sign - --entitlements QuickLook/QuickLook.entitlements "$APP/Contents/PlugIns/ScanQuickLook.appex"
codesign --force --sign - "$APP"
swift build --disable-sandbox --build-system native -c release --product scan-cli >/tmp/scan-cli-build.log
BIN=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
cp "$BIN/scan-cli" "$PWD/dist/bin/scan"
touch "$APP"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
pluginkit -a "$APP/Contents/PlugIns/ScanQuickLook.appex" >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true
printf '\nBuilt %s\n' "$APP"
du -sh "$APP"
