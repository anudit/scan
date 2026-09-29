#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clang++ -dynamiclib -mmacosx-version-min=14.0 -O2 -Wl,-dead_strip -Wl,-force_load,Vendor/DuckDB/libduckdb_static.a \
    -Wl,-force_load,Vendor/DuckDB/libduckdb_generated_extension_loader.a \
    -Wl,-force_load,Vendor/DuckDB/libparquet_extension.a \
    -Wl,-force_load,Vendor/DuckDB/libjson_extension.a \
    -Wl,-force_load,Vendor/DuckDB/libcore_functions_extension.a \
    -Wl,-force_load,Vendor/DuckDB/libicu_extension.a \
    Vendor/DuckDB/libautocomplete_extension.a Vendor/DuckDB/libtpcds_extension.a \
    Vendor/DuckDB/libtpch_extension.a Vendor/DuckDB/libduckdb*.a \
    -Wl,-install_name,@rpath/libduckdb_shared.dylib \
    -o Vendor/DuckDB/libduckdb_shared.dylib
xcrun strip -x Vendor/DuckDB/libduckdb_shared.dylib
