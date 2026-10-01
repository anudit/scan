#!/usr/bin/env python3
"""Compare pinned baseline and tailored libraries with Scan's tests and benchmark.

Build ScanBench (release), run swift test once to build the XCTest bundle, and
run scripts/build-tailored-duckdb.py first. Pass a million-row Parquet fixture.
"""
import ctypes as c
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'bench/results/duckdb-tailored'
LIBRARIES = {'baseline': ROOT / 'dist/Scan.app/Contents/Frameworks/libduckdb_shared.dylib',
             **{name: ROOT / f'.build/duckdb-tailored/{name}/libduckdb_shared.dylib'
                for name in ['no-autocomplete', 'lean']}}

class Result(c.Structure):
    _fields_ = [(name, c.c_uint64) for name in ['columns', 'rows', 'changed']] + [
        (name, c.c_void_p) for name in ['column_data', 'error', 'internal']]

PROBES = {
    'version': 'SELECT version()',
    'linked_extensions': 'SELECT extension_name FROM duckdb_extensions() WHERE installed AND loaded ORDER BY 1',
    'nested_json': "SELECT json_extract_string('{\"city\":\"Paris\"}', '$.city'), CAST(list_slice([1,2,3],1,2) AS VARCHAR)",
    'date_timestamp': "SELECT DATE '2026-10-01', TIMESTAMP '2026-10-01 12:30:00'",
    'timestamp_tz_offset': "SELECT CAST(TIMESTAMPTZ '2026-10-01 12:30:00+05:30' AS VARCHAR)",
    'timestamp_tz_named': "SELECT CAST(TIMESTAMPTZ '2026-10-01 12:30:00 Asia/Kolkata' AS VARCHAR)",
    'timezone_conversion': "SELECT CAST(timezone('America/New_York', TIMESTAMPTZ '2026-10-01 12:30:00+00') AS VARCHAR)",
    'unicode_collation': "SELECT 'é' COLLATE fr < 'z' COLLATE fr",
    'approx_distinct': 'SELECT approx_count_distinct(i) FROM range(1000) t(i)',
    'text_filter': "SELECT contains(lower('Éclair COVID'), lower('covid')), starts_with('alpha', 'al')",
}

def probe(path):
    db = c.CDLL(str(path))
    db.duckdb_open.argtypes = [c.c_char_p, c.POINTER(c.c_void_p)]
    db.duckdb_connect.argtypes = [c.c_void_p, c.POINTER(c.c_void_p)]
    db.duckdb_query.argtypes = [c.c_void_p, c.c_char_p, c.POINTER(Result)]
    db.duckdb_result_error.argtypes = [c.POINTER(Result)]
    db.duckdb_result_error.restype = c.c_char_p
    db.duckdb_row_count.argtypes = [c.POINTER(Result)]
    db.duckdb_row_count.restype = c.c_uint64
    db.duckdb_column_count.argtypes = [c.POINTER(Result)]
    db.duckdb_column_count.restype = c.c_uint64
    db.duckdb_value_varchar.argtypes = [c.POINTER(Result), c.c_uint64, c.c_uint64]
    db.duckdb_value_varchar.restype = c.c_void_p
    db.duckdb_free.argtypes = [c.c_void_p]
    db.duckdb_destroy_result.argtypes = [c.POINTER(Result)]
    db.duckdb_disconnect.argtypes = [c.POINTER(c.c_void_p)]
    db.duckdb_close.argtypes = [c.POINTER(c.c_void_p)]
    database, connection = c.c_void_p(), c.c_void_p()
    assert db.duckdb_open(None, c.byref(database)) == 0
    assert db.duckdb_connect(database, c.byref(connection)) == 0
    results = {}
    try:
        # Match Scan's offline extension configuration.
        for name, sql in [('config', 'SET autoinstall_known_extensions=false'),
                          ('config2', 'SET autoload_known_extensions=false'), *PROBES.items()]:
            result = Result()
            try:
                status = db.duckdb_query(connection, sql.encode(), c.byref(result))
                if status:
                    results[name] = {'ok': False, 'error': db.duckdb_result_error(c.byref(result)).decode()}
                else:
                    rows = []
                    for row in range(db.duckdb_row_count(c.byref(result))):
                        values = []
                        for col in range(db.duckdb_column_count(c.byref(result))):
                            value = db.duckdb_value_varchar(c.byref(result), col, row)
                            values.append(c.string_at(value).decode() if value else None)
                            db.duckdb_free(value)
                        rows.append(values)
                    results[name] = {'ok': True, 'rows': rows}
            finally:
                db.duckdb_destroy_result(c.byref(result))
    finally:
        db.duckdb_disconnect(c.byref(connection))
        db.duckdb_close(c.byref(database))
    return results

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--probe':
        print(json.dumps(probe(Path(sys.argv[2])), indent=2))
        sys.exit(0)
    fixture = Path(sys.argv[1]).resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    summary = {'dataset': str(fixture), 'rounds': 3, 'inner_runs': 3, 'builds': {}}
    for name, library in LIBRARIES.items():
        env = {**os.environ, 'DYLD_LIBRARY_PATH': str(library.parent),
               'DYLD_PRINT_LIBRARIES': '1', 'SCAN_PERF_FILE': str(fixture)}
        with (OUT / f'{name}-tests.log').open('w') as log:
            status = subprocess.run(['/Applications/Xcode.app/Contents/Developer/usr/bin/xctest',
                                     str(ROOT / '.build/debug/ScanPackageTests.xctest')],
                                    env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        probes = json.loads(subprocess.check_output([sys.executable, __file__, '--probe', str(library)]))
        summary['builds'][name] = {'library_bytes': library.stat().st_size,
                                 'tests_exit_code': status, 'probes': probes, 'samples_ms': {},
                                 'peak_rss_mb': []}
        assert status == 0, f'{name}: tests failed'
        assert str(library) in (OUT / f'{name}-tests.log').read_text(), 'Wrong library loaded'
        print(f'{name}: tests passed; probes recorded', flush=True)
    baseline_probes = summary['builds']['baseline']['probes']
    for name, result in summary['builds']['no-autocomplete']['probes'].items():
        if name != 'linked_extensions':
            assert result == baseline_probes[name], f'no-autocomplete: {name} changed'
    summary['no_autocomplete_probes_match_baseline'] = True
    # Warm the file cache equally before alternating timed processes.
    subprocess.run([str(ROOT / '.build/release/ScanBench'), str(fixture)],
                   stdout=subprocess.DEVNULL, check=True)
    for round_index in range(3):
        order = list(LIBRARIES) if round_index % 2 == 0 else list(reversed(LIBRARIES))
        for name in order:
            library = LIBRARIES[name]
            env = {**os.environ, 'DYLD_LIBRARY_PATH': str(library.parent), 'DYLD_PRINT_LIBRARIES': '1'}
            report = OUT / f'{name}-engine-{round_index + 1}.json'
            with report.with_suffix('.log').open('w') as log:
                subprocess.run([str(ROOT / '.build/release/ScanBench'), str(fixture), str(report)],
                               env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            assert str(library) in report.with_suffix('.log').read_text(), 'Wrong library loaded'
            measured = json.loads(report.read_text())
            build = summary['builds'][name]
            for metric, samples in measured['runs'].items():
                build['samples_ms'].setdefault(metric, []).extend(samples)
            build['peak_rss_mb'].append(measured['peak_rss_mb'])
            print(f'round {round_index + 1}: {name} done', flush=True)
    for build in summary['builds'].values():
        build['median_ms'] = {key: statistics.median(samples) for key, samples in build['samples_ms'].items()}
    (OUT / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
