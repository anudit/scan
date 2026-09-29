#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=v1.5.6
ARCH=$(uname -m)
[[ "$ARCH" == arm64 ]] || { echo 'This build currently supports Apple Silicon only.' >&2; exit 1; }
mkdir -p Vendor/DuckDB Sources/CDuckDB/include
ARCHIVE=$(mktemp -t scan-duckdb).zip
trap 'rm -f "$ARCHIVE"' EXIT
curl -L --fail "https://github.com/duckdb/duckdb/releases/download/$VERSION/static-libs-osx-arm64.zip" -o "$ARCHIVE"
EXPECTED=e77c382fba15e3f5c0b3265d12e3a4de534699fdb91bcc9d10d4a857a58103d5
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'DuckDB archive checksum mismatch' >&2; exit 1; }
unzip -oq "$ARCHIVE" '*.a' -d Vendor/DuckDB
unzip -p "$ARCHIVE" duckdb.h > Sources/CDuckDB/include/duckdb.h
