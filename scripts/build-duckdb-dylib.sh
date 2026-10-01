#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep JSON, Parquet, core SQL functions and ICU; omit unused autocomplete.
VERSION=1.5.6
SOURCE_SHA=1fadcbe9e69e1470f9093b6bcde08daf477d729c449e59a807f45c346622099b
BUILD_DIR="$PWD/.build/duckdb-tailored"
SOURCE_ARCHIVE="$BUILD_DIR/source.tar.gz"
STAMP=Vendor/DuckDB/.tailored-build.sha256
LIBRARY=Vendor/DuckDB/libduckdb_shared.dylib
if [[ ! -f Vendor/DuckDB/libduckdb_static.a ]]; then scripts/bootstrap.sh; fi
# Include archive and script hashes so an older/full library is rebuilt automatically.
BUILD_KEY=$(shasum -a 256 scripts/build-duckdb-dylib.sh scripts/build-tailored-duckdb.py Vendor/DuckDB/*.a | shasum -a 256 | cut -d ' ' -f 1)
if [[ -f "$LIBRARY" && -f Vendor/DuckDB/LICENSE && -f "$STAMP" && "$(head -n 1 "$STAMP")" == "$BUILD_KEY" ]]; then
    LIBRARY_SHA=$(shasum -a 256 "$LIBRARY" | cut -d ' ' -f 1)
    if [[ "$(tail -n 1 "$STAMP")" == "$LIBRARY_SHA" ]]; then exit 0; fi
fi
mkdir -p "$BUILD_DIR"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
    curl -L --fail "https://codeload.github.com/duckdb/duckdb/tar.gz/refs/tags/v$VERSION" -o "$SOURCE_ARCHIVE.download"
    mv "$SOURCE_ARCHIVE.download" "$SOURCE_ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$SOURCE_ARCHIVE" | cut -d ' ' -f 1)
[[ "$ACTUAL" == "$SOURCE_SHA" ]] || { echo 'DuckDB source checksum mismatch' >&2; exit 1; }
tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_DIR"
python3 scripts/build-tailored-duckdb.py "$BUILD_DIR/duckdb-$VERSION" --variant no-autocomplete
cp "$BUILD_DIR/duckdb-$VERSION/LICENSE" Vendor/DuckDB/LICENSE
cp "$BUILD_DIR/no-autocomplete/libduckdb_shared.dylib" "$LIBRARY.tmp"
mv "$LIBRARY.tmp" "$LIBRARY"
LIBRARY_SHA=$(shasum -a 256 "$LIBRARY" | cut -d ' ' -f 1)
printf '%s\n%s\n' "$BUILD_KEY" "$LIBRARY_SHA" > "$STAMP"
