<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Scan app icon">
</p>

<h1 align="center">Scan</h1>

<p align="center">A fast, native, read-only macOS viewer for Parquet, CSV, TSV, JSONL/NDJSON, SQLite and DuckDB files.</p>

<p align="center">
  <img src="docs/screenshot.png" width="512" height="auto" alt="Scan app screenshot">
</p>

Scan opens Parquet, CSV, TSV, JSONL (`.jsonl`, `.ndjson`), gzip-compressed CSV/TSV/JSONL (`.csv.gz`, `.tsv.gz`, `.jsonl.gz`, `.ndjson.gz`), DuckDB and SQLite files. It can also preview remote Parquet files from HTTPS URLs, such as Hugging Face datasets, without downloading the whole file. JSONL files contain one JSON object per line; fields become columns with automatically inferred types, and the inspector shows JSON cells as a tree you can expand. It uses DuckDB for queries and a custom AppKit grid for large files, so a 4 GB Parquet file paints its first rows in well under half a second. Files are never modified.

- **Filter, sort and group** with DuckDB `WHERE` expressions, multi-column sorts and group-bys.
- **Quick Look**: press space on a file in Finder to see its first 10 rows.
- **Ask**: type a question and Scan turns it plus the file's schema into a read-only DuckDB query. It uses Apple's on-device Foundation Models framework, so it needs macOS 26 or later with Apple Intelligence available.
- **Export** the current filtered and sorted view as a new CSV, JSON, JSON Lines or Parquet file.
- **Light and dark** appearance, or follow the system, from **Settings → Appearance**.
- **CLI**: `scan file.parquet` opens a file from the terminal, and `scan https://…/file.parquet` opens a remote one.

## Remote Parquet

Open a Parquet file directly from HTTPS without downloading it first with **File → Open URL…** (⇧⌘O), or from the CLI:

```sh
dist/bin/scan 'https://huggingface.co/datasets/org/name/resolve/main/file.parquet'
```

Hugging Face `/blob/` links are rewritten to `/resolve/` automatically. Scan reads the Parquet footer and only the row groups needed to paint the visible pages, using HTTP range requests. Downloaded ranges are kept in a sparse cache file at `~/Library/Caches/dev.scan.app/RemoteParquet`, which is capped at 5 GB and evicts the least recently used files first. Reopening a remote file therefore fetches only what is still missing. To open gated or private repositories, save a token in **Settings → Hugging Face** (kept in the login keychain), or set `HF_TOKEN` (or `HUGGING_FACE_HUB_TOKEN` / `HUGGINGFACE_TOKEN`) when launching Scan from a terminal.

Actions that need every row — applying a filter, sorting, grouping, exporting, or Ask — download the remaining row groups first. The status bar shows how much of the remote file is cached. Only Parquet is supported remotely, the server must support HTTP range requests, and remote files are not watched for changes.

## Download and install

Download [Scan v1.1.0 for Apple Silicon Macs](https://github.com/anudit/scan/releases/tag/v1.1.0). Requires macOS 14 or later. Intel Macs are not supported by this release.

Open the `.dmg` and drag **Scan.app** to **Applications**, or extract the `.zip` and move **Scan.app** there. The ZIP also includes the optional `bin/scan` command, which you can copy to a directory on your `PATH` after installing the app.

This release is ad hoc signed and is not notarized. If macOS blocks the first launch, open **System Settings → Privacy & Security → Open Anyway** after trying to open Scan, then confirm. See [Apple's instructions](https://support.apple.com/en-us/102445).

Use **File → Open…**, drop a supported file onto Scan, or choose **Open With → Scan** in Finder. Set it as the default viewer with **Get Info → Open with → Scan → Change All…**. The Ask feature additionally requires macOS 26 or later with Apple Intelligence available.

## Build

Requires an Apple Silicon Mac running macOS 14 or later, Xcode with the macOS SDK, Python 3, CMake and Ninja. Install the additional build tools with `brew install cmake ninja` if needed.

```sh
scripts/build.sh
open dist/Scan.app
dist/bin/scan /path/to/file.parquet
```

On first use the build downloads DuckDB 1.5.6 archives and matching source, and checks their SHA-256 hashes. It builds a tailored library containing JSON, Parquet, core SQL functions and ICU, with autocomplete omitted. The Parquet extension is compiled from source with `scripts/patches/duckdb-parquet-page-seek.patch`, which lets deep row jumps seek past whole pages instead of decoding them. The app bundle includes the Quick Look preview extension, and `scripts/build.sh` registers it with Launch Services.

Create downloadable release archives after building with `scripts/package-release.sh`. The v1.1.0 app occupies approximately 48 MiB on disk; the archives are compressed.

Run the engine and query tests with:

```sh
swift test --disable-sandbox --build-system native
```

To exercise the remote reader against a real server, set `SCAN_REMOTE_URL` to a public Parquet URL:

```sh
SCAN_REMOTE_URL='https://huggingface.co/…/file.parquet' swift test --disable-sandbox --build-system native --filter testLiveRemoteURL
```

## Benchmarks: Scan versus Tad 0.14

These are medians of three runs on the same M2 Max, 64 GB Mac running macOS 27.0. Memory is the total process-tree physical footprint reported by `top`. The [raw Scan runs](bench/results/scan-v0.1/) and [Tad runs](bench/results/) are saved as JSON.

| Test | Tad | Scan |
|---|---:|---:|
| App bundle on disk | 677 MB | 49 MB |
| 4 GB Parquet: first painted rows | ~2–3 s, estimated | 0.367 s |
| 4 GB Parquet: CPU quiescence | 5.4 s | 2.2 s |
| 4 GB Parquet: peak / idle memory | 699 / 562 MB | 99 / 95 MB |
| 4 GB Parquet: idle CPU | 0.9% | 0.27% |
| Small CSV: CPU quiescence | 4.3 s | 2.2 s |
| Small CSV: peak / idle memory | 372 / 311 MB | 87 / 84 MB |
| Scroll stress: mean / peak CPU | 67 / 107% | 12.8 / 53.9% |
| Scroll stress: CPU time | 7.4 CPU-s | 1.66 CPU-s |
| Scroll stress: peak / later idle memory | 875 / 589 MB | 151 / 139 MB |
| Process count | 4 | 1 |

## License

Scan is released under the [MIT License](LICENSE). It bundles [DuckDB](https://duckdb.org), which is also [MIT-licensed](https://github.com/duckdb/duckdb/blob/v1.5.6/LICENSE). The app includes a copy at `Contents/Resources/DuckDB-LICENSE`.
