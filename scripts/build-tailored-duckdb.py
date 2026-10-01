#!/usr/bin/env python3
"""Relink pinned DuckDB archives with a matching, reduced extension loader.

Usage: scripts/build-tailored-duckdb.py /path/to/duckdb-1.5.6
Outputs experimental libraries under .build/duckdb-tailored; leaves Vendor and dist unchanged.
Requires the v1.5.6 source and the archives fetched by scripts/bootstrap.sh.
"""
import argparse
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('--variant', choices=['no-autocomplete', 'lean', 'all'], default='all')
args = parser.parse_args()
source = args.source.resolve()
vendor = root / 'Vendor/DuckDB'
for variant, extensions in [('no-autocomplete', ['json', 'icu', 'core_functions', 'parquet']),
                            ('lean', ['json', 'core_functions', 'parquet'])]:
    if args.variant not in ['all', variant]:
        continue
    folder = root / '.build/duckdb-tailored' / variant
    subprocess.run(['cmake', '-S', str(source), '-B', str(folder), '-G', 'Ninja',
                    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                    '-DBUILD_EXTENSIONS=' + ';'.join(extensions), '-DBUILD_UNITTESTS=OFF',
                    '-DBUILD_SHELL=OFF', '-DOVERRIDE_GIT_DESCRIBE=v1.5.6'], check=True)
    subprocess.run(['cmake', '--build', str(folder), '--target',
                    'duckdb_generated_extension_loader', '-j', '4'], check=True)
    output = folder / 'libduckdb_shared.dylib'
    cmd = ['clang++', '-dynamiclib', '-mmacosx-version-min=14.0', '-O2', '-Wl,-dead_strip',
           f'-Wl,-force_load,{vendor}/libduckdb_static.a',
           f'-Wl,-force_load,{folder}/extension/libduckdb_generated_extension_loader.a']
    cmd += [f'-Wl,-force_load,{vendor}/lib{ext}_extension.a' for ext in extensions]
    cmd += [str(p) for p in sorted(vendor.glob('libduckdb*.a'))
            if p.name not in ['libduckdb_static.a', 'libduckdb_generated_extension_loader.a']]
    cmd += ['-Wl,-install_name,@rpath/libduckdb_shared.dylib', '-o', str(output)]
    subprocess.run(cmd, check=True)
    subprocess.run(['xcrun', 'strip', '-x', str(output)], check=True)
    print(f'{variant}: {output.stat().st_size / 1024**2:.2f} MiB', flush=True)
