#!/usr/bin/env python3
"""
Headless DuckDB timings for the queries a Tad-like viewer issues. This is the engine
"floor" a native app embedding DuckDB should approach (UI overhead excluded).

Usage: python3 bench/engine_floor.py /path/to/file.parquet [runs=5]
Requires: pip install duckdb
"""
import json, resource, statistics, sys, time
import duckdb

path = sys.argv[1]
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
con = duckdb.connect()
con.execute(f"CREATE VIEW t AS SELECT * FROM read_parquet('{path}')")

# Display columns: long text/list columns truncated like a grid cell would be.
cols = "corpusid, left(openaccessinfo, 120) AS openaccessinfo, left(abstract, 120) AS abstract, left(embedding::VARCHAR, 120) AS embedding"
Q = {
    "schema (DESCRIBE)": "DESCRIBE t",
    "row count": "SELECT count(*) FROM t",
    "first page (100 rows)": f"SELECT {cols} FROM t LIMIT 100",
    "deep page (offset 500k)": f"SELECT {cols} FROM t LIMIT 100 OFFSET 500000",
    "last page (offset 999.9k)": f"SELECT {cols} FROM t LIMIT 100 OFFSET 999900",
    "sort by corpusid, top page": f"SELECT {cols} FROM t ORDER BY corpusid DESC LIMIT 100",
    "filter abstract ILIKE '%covid%' + count": "SELECT count(*) FROM t WHERE abstract ILIKE '%covid%'",
    "pivot: group by license (json)": "SELECT json_extract_string(openaccessinfo, '$.license') AS lic, count(*), avg(length(abstract)) FROM t GROUP BY 1 ORDER BY 2 DESC",
    "column stats: min/max/approx_distinct corpusid": "SELECT min(corpusid), max(corpusid), approx_count_distinct(corpusid) FROM t",
}

out = {}
for name, q in Q.items():
    ts = []
    for i in range(runs):
        t = time.perf_counter()
        con.execute(q).fetchall()
        ts.append((time.perf_counter() - t) * 1000)
    out[name] = {"first_ms": round(ts[0], 1), "median_ms": round(statistics.median(ts), 1)}
    print(f"{name:48s} first {ts[0]:9.1f} ms   median {statistics.median(ts):9.1f} ms", flush=True)

rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576  # bytes on macOS
ru = resource.getrusage(resource.RUSAGE_SELF)
print(f"peak RSS {rss:.0f} MB, cpu user {ru.ru_utime:.1f}s sys {ru.ru_stime:.1f}s, duckdb {duckdb.__version__}")
out["_process"] = {"peak_rss_mb": round(rss), "cpu_user_s": round(ru.ru_utime, 1), "cpu_sys_s": round(ru.ru_stime, 1), "duckdb": duckdb.__version__}
json.dump(out, open("bench/results/engine_floor.json", "w"), indent=1)
