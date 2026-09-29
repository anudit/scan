# Benchmarks

Results are summarized in the [top-level README](../README.md#benchmarks-scan-versus-tad-014).

- `bench_app.py`: launches an app on a file and samples CPU / memory / energy impact (`top`, no sudo) across the whole process tree. Optional `--action` phase.
- `scroll_stress.swift`: posts 60 Hz scroll-wheel events over the app's window. The terminal needs Accessibility permission. Build it with `swiftc -O bench/scroll_stress.swift -o bench/.scroll_stress`.
- `engine_floor.py`: headless DuckDB timings for viewer-style queries. Needs `pip install duckdb`.
- `results/`: raw JSON with per-second samples.
