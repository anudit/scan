# Tailored DuckDB experiment — 2026-10-01

Removing autocomplete preserves tested behavior and modestly reduces size. Removing
ICU saves substantially more space but loses named timezones and locale collations.
Neither variant demonstrates a meaningful query speed improvement.

| Variant | Signed app | Signed DuckDB library | XCTest | Extra SQL probes |
|---|---:|---:|---|---|
| Current release | 49.04 MiB | 45.26 MiB | 21 passed | All passed |
| Without autocomplete | 47.77 MiB | 43.99 MiB | 21 passed | Same results as baseline, excluding extension inventory |
| Without autocomplete or ICU | 39.76 MiB | 35.98 MiB | 21 passed | Named timezone parsing, timezone conversion, French collation fail |

The full suite includes plain CSV, gzip TSV, plain/gzip JSONL, nested values,
SQLite/DuckDB databases, Parquet round trips, filtering, sorting, grouping,
read-only enforcement, Ask queries, and the million-row paging performance check.
The additional probes cover JSON/list functions, date/timestamp display,
timezone operations, collations, approximate distinct counts, and text filters.
These checks are representative; they do not establish parity for every arbitrary
SQL expression or every DuckDB database created with optional extensions.

## Engine timings

Warm filesystem cache, 3.7 GiB `first_1M_rows.parquet` fixture, release ScanBench.
Medians of nine samples per metric (three processes, three runs each). Variant
order alternates between rounds. Small differences are not evidence of a speedup.

| Operation | Current | No autocomplete | No autocomplete / ICU |
|---|---:|---:|---:|
| Engine initialization | 5.85 ms | 5.85 ms | 5.48 ms |
| First 256 rows | 28.24 ms | 28.40 ms | 27.89 ms |
| Filter and count | 264.87 ms | 267.88 ms | 264.52 ms |
| JSON license aggregation | 372.15 ms | 371.81 ms | 374.84 ms |
| Sorted first page, including ID ordering | 800.57 ms | 795.53 ms | 795.80 ms |

The final row adds the separately measured median ID-ordering and page-fetch times;
it is not a median of combined per-run times. Peak RSS varied across processes;
there is no established memory improvement. No UI, cold-cache, or Finder latency
measurements were taken.

## Build and reproducibility

Both variants reuse the exact v1.5.6 core/extension archives in `Vendor/DuckDB`.
Only the official CMake-generated static extension loader is recompiled with the
selected extension set before relinking and stripping the dynamic library. This
isolates extension removal from changes to compiler settings or core query code.
The no-autocomplete build retains JSON, Parquet, core functions and ICU; the lean
build retains JSON, Parquet and core functions. TPC-H/TPC-DS are not loaded in the
baseline, so they are not credited with any size savings.

Source: `https://codeload.github.com/duckdb/duckdb/tar.gz/refs/tags/v1.5.6`

Source archive SHA-256:
`1fadcbe9e69e1470f9093b6bcde08daf477d729c449e59a807f45c346622099b`.

From the repository root:

```sh
python3 scripts/build-tailored-duckdb.py .build/duckdb-tailored/duckdb-1.5.6
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --build-system native
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift build --disable-sandbox --build-system native -c release --product ScanBench
python3 bench/compare_duckdb_builds.py /path/to/first_1M_rows.parquet
```

`comparison.json` includes all samples, probes, library sizes, and packaged bundle
sizes. The comparison script recreates test/benchmark data; packaged app sizes were
added after signing. Logs confirm the selected library with `DYLD_PRINT_LIBRARIES`.
Baseline benchmark loading uses the library in `dist/Scan.app`; tailored loading
uses the experimental libraries in `.build/duckdb-tailored`. Signed library sizes
are measured separately because stripping/re-signing changes signature overhead.

Separately packaged, ad hoc signed apps are available locally at
`dist/tailored/Scan.app` and `dist/tailored/Scan-lean.app`; both passed deep signature
verification. The default `dist/Scan.app`, vendor library, and production build
script remain unchanged. Use the ICU-retaining build for the compatible experiment;
the lean app is retained only for evaluating the documented feature losses.

After this experiment, v1.0 adopted the ICU-retaining no-autocomplete variant as the default build. The retained numbers describe the original pre-v1.0 baseline. Rerunning the comparison script now uses the installed `dist/Scan.app` as its baseline, which may already be tailored.
