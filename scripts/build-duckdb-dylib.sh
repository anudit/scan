#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep JSON, Parquet, Excel, core SQL functions and ICU; omit unused autocomplete.
VERSION=1.5.6
SOURCE_SHA=1fadcbe9e69e1470f9093b6bcde08daf477d729c449e59a807f45c346622099b
BUILD_DIR="$PWD/.build/duckdb-tailored"
SOURCE_ARCHIVE="$BUILD_DIR/source.tar.gz"
STAMP=Vendor/DuckDB/.tailored-build.sha256
LIBRARY=Vendor/DuckDB/libduckdb_shared.dylib
if [[ ! -f Vendor/DuckDB/libduckdb_static.a ]]; then scripts/bootstrap.sh; fi
# Include archive and script hashes so an older/full library is rebuilt automatically.
BUILD_KEY=$(shasum -a 256 scripts/build-duckdb-dylib.sh scripts/build-tailored-duckdb.py scripts/patches/*.patch Vendor/DuckDB/*.a | shasum -a 256 | cut -d ' ' -f 1)
if [[ -f "$LIBRARY" && -f Vendor/DuckDB/LICENSE && -f Vendor/DuckDB/minizip-ng-LICENSE && -f "$STAMP" && "$(head -n 1 "$STAMP")" == "$BUILD_KEY" ]]; then
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
# The Excel extension reads .xlsx archives through minizip-ng. Build the version its vcpkg
# port pins as a static library with only zlib (from the SDK), so nothing comes from Homebrew.
MINIZIP_VERSION=4.0.7
MINIZIP_SHA=a87f1f734f97095fe1ef0018217c149d53d0f78438bcb77af38adc21dff2dfbc
MINIZIP_DIR="$PWD/.build/minizip-ng"
MINIZIP_ARCHIVE="$MINIZIP_DIR/source.tar.gz"
mkdir -p "$MINIZIP_DIR"
if [[ ! -f "$MINIZIP_ARCHIVE" ]]; then
    curl -L --fail "https://codeload.github.com/zlib-ng/minizip-ng/tar.gz/refs/tags/$MINIZIP_VERSION" -o "$MINIZIP_ARCHIVE.download"
    mv "$MINIZIP_ARCHIVE.download" "$MINIZIP_ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$MINIZIP_ARCHIVE" | cut -d ' ' -f 1)
[[ "$ACTUAL" == "$MINIZIP_SHA" ]] || { echo 'minizip-ng source checksum mismatch' >&2; exit 1; }
rm -rf "$MINIZIP_DIR/minizip-ng-$MINIZIP_VERSION" "$MINIZIP_DIR/build" "$MINIZIP_DIR/install"
tar -xzf "$MINIZIP_ARCHIVE" -C "$MINIZIP_DIR"
cmake -S "$MINIZIP_DIR/minizip-ng-$MINIZIP_VERSION" -B "$MINIZIP_DIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX="$MINIZIP_DIR/install" -DBUILD_SHARED_LIBS=OFF -DMZ_LIB_SUFFIX=-ng \
    -DMZ_FETCH_LIBS=OFF -DMZ_ZLIB=ON -DMZ_BZIP2=OFF -DMZ_LZMA=OFF -DMZ_ZSTD=OFF -DMZ_LIBCOMP=OFF \
    -DMZ_PKCRYPT=OFF -DMZ_WZAES=OFF -DMZ_OPENSSL=OFF -DMZ_ICONV=OFF -DMZ_COMPAT=OFF
cmake --build "$MINIZIP_DIR/build" --target install
# Extract fresh so the parquet patch always applies to pristine source.
rm -rf "$BUILD_DIR/duckdb-$VERSION"
tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_DIR"
python3 scripts/build-tailored-duckdb.py "$BUILD_DIR/duckdb-$VERSION" --variant no-autocomplete --minizip "$MINIZIP_DIR/install"
cp "$BUILD_DIR/duckdb-$VERSION/LICENSE" Vendor/DuckDB/LICENSE
cp "$MINIZIP_DIR/minizip-ng-$MINIZIP_VERSION/LICENSE" Vendor/DuckDB/minizip-ng-LICENSE
cp "$BUILD_DIR/no-autocomplete/_deps/excel_extension_fc-src/LICENSE" Vendor/DuckDB/duckdb-excel-LICENSE
cp "$BUILD_DIR/no-autocomplete/libduckdb_shared.dylib" "$LIBRARY.tmp"
mv "$LIBRARY.tmp" "$LIBRARY"
LIBRARY_SHA=$(shasum -a 256 "$LIBRARY" | cut -d ' ' -f 1)
printf '%s\n%s\n' "$BUILD_KEY" "$LIBRARY_SHA" > "$STAMP"
