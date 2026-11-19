#!/usr/bin/env python3
"""Relink pinned DuckDB archives with a matching, reduced extension loader.

Usage: scripts/build-tailored-duckdb.py /path/to/duckdb-1.5.6
Outputs experimental libraries under .build/duckdb-tailored; leaves Vendor and dist unchanged.
Requires the v1.5.6 source and the archives fetched by scripts/bootstrap.sh.
The Parquet extension is compiled from source with scripts/patches applied, so deep row
seeks skip whole pages instead of decoding them. The Excel extension is fetched by DuckDB's
build at the commit pinned in its .github/config/extensions/excel.cmake and compiled from source.
"""
import argparse
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('--minizip', type=pathlib.Path, help='minizip-ng install prefix, needed for Excel')
parser.add_argument('--variant', choices=['no-autocomplete', 'lean', 'all'], default='all')
args = parser.parse_args()
if args.variant in ['all', 'no-autocomplete'] and not args.minizip:
    parser.error('--minizip is required to build the Excel extension')
source = args.source.resolve()
vendor = root / 'Vendor/DuckDB'
for patch in sorted((root / 'scripts/patches').glob('duckdb-*.patch')):
    # Apply once; a clean reverse dry run means the source already carries the patch.
    applied = subprocess.run(['patch', '-p1', '-R', '--dry-run', '-s', '-f', '-i', str(patch)],
                             cwd=source, capture_output=True).returncode == 0
    if not applied:
        subprocess.run(['patch', '-p1', '-s', '-f', '-i', str(patch)], cwd=source, check=True)
for variant, extensions in [('no-autocomplete', ['json', 'icu', 'core_functions', 'parquet', 'excel']),
                            ('lean', ['json', 'core_functions', 'parquet'])]:
    if args.variant not in ['all', variant]:
        continue
    folder = root / '.build/duckdb-tailored' / variant
    subprocess.run(['cmake', '-S', str(source), '-B', str(folder), '-G', 'Ninja',
                    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                    '-DBUILD_EXTENSIONS=' + ';'.join(extensions), '-DBUILD_UNITTESTS=OFF',
                    '-DBUILD_SHELL=OFF', '-DOVERRIDE_GIT_DESCRIBE=v1.5.6']
                   # vcpkg puts its include root on the path; the extension includes "minizip-ng/mz.h".
                   + ([f'-DCMAKE_PREFIX_PATH={args.minizip.resolve()}', f'-DCMAKE_CXX_FLAGS=-I{args.minizip.resolve()}/include']
                      if 'excel' in extensions else []), check=True)
    subprocess.run(['cmake', '--build', str(folder), '--target',
                    'duckdb_generated_extension_loader', 'parquet_extension']
                   + (['excel_extension'] if 'excel' in extensions else []) + ['-j', '8'], check=True)
    output = folder / 'libduckdb_shared.dylib'
    cmd = ['clang++', '-dynamiclib', '-mmacosx-version-min=14.0', '-O2', '-Wl,-dead_strip',
           f'-Wl,-force_load,{vendor}/libduckdb_static.a',
           f'-Wl,-force_load,{folder}/extension/libduckdb_generated_extension_loader.a']
    # Parquet and Excel are built from source above; the rest come from the release archives.
    cmd += [f'-Wl,-force_load,{folder}/extension/{ext}/lib{ext}_extension.a' if ext in ['parquet', 'excel']
            else f'-Wl,-force_load,{vendor}/lib{ext}_extension.a' for ext in extensions]
    cmd += [str(p) for p in sorted(vendor.glob('libduckdb*.a'))
            if p.name not in ['libduckdb_static.a', 'libduckdb_generated_extension_loader.a']]
    if 'excel' in extensions:
        # Expat and zlib are system libraries; minizip-ng is linked statically.
        cmd += [str(args.minizip.resolve() / 'lib/libminizip-ng.a'), '-lexpat', '-lz']
    cmd += ['-Wl,-install_name,@rpath/libduckdb_shared.dylib', '-o', str(output)]
    subprocess.run(cmd, check=True)
    subprocess.run(['xcrun', 'strip', '-x', str(output)], check=True)
    print(f'{variant}: {output.stat().st_size / 1024**2:.2f} MiB', flush=True)
