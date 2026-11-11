#!/usr/bin/env python3
"""Verify the vendored Creator runtime offline; explicitly rebuild from pinned npm archives."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'ThirdParty/three'


def verify():
    manifest = json.loads((VENDOR / 'manifest.json').read_text())
    data = (VENDOR / 'wm-three-r180.js').read_bytes()
    if hashlib.sha256(data).hexdigest() != manifest['bundleSHA256']:
        raise ValueError('Creator Three.js bundle digest mismatch')
    if not (VENDOR / 'LICENSE').read_text().startswith('The MIT License'):
        raise ValueError('Creator Three.js license missing')
    return manifest


def fetch(record, destination):
    with urllib.request.urlopen(record['url'], timeout=60) as response:
        data = response.read(32 * 1024 * 1024)
    algorithm, digest = record['integrity'].split('-', 1)
    if algorithm != 'sha512' or base64.b64encode(hashlib.sha512(data).digest()).decode() != digest:
        raise ValueError('Pinned dependency integrity mismatch')
    archive = destination.with_suffix('.tgz')
    archive.write_bytes(data)
    destination.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter='data')


def rebuild(manifest):
    # No npm lifecycle scripts, global install or user configuration; arm64 macOS build tool only.
    with tempfile.TemporaryDirectory(prefix='wm-three-build-') as directory:
        work = Path(directory)
        fetch(manifest, work / 'three')
        fetch(manifest['builderBinary'], work / 'esbuild')
        modules = work / 'node_modules'
        modules.mkdir()
        (modules / 'three').symlink_to(work / 'three/package', target_is_directory=True)
        (work / 'entry.js').write_bytes((VENDOR / 'entry.js').read_bytes())
        tool = work / 'esbuild/package/bin/esbuild'
        tool.chmod(0o755)
        output = work / 'bundle.js'
        subprocess.run([str(tool), str(work / 'entry.js'), '--bundle', '--minify', '--format=iife',
                        '--global-name=WMLib', '--target=safari18', '--legal-comments=inline',
                        '--outfile=' + str(output)], check=True)
        data = output.read_bytes()
        if hashlib.sha256(data).hexdigest() != manifest['bundleSHA256']:
            raise ValueError('Rebuild differs from the reviewed runtime')
        (VENDOR / 'wm-three-r180.js').write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rebuild', action='store_true', help='Download pinned archives and reproduce the exact bundle')
    args = parser.parse_args()
    manifest = verify()
    if args.rebuild:
        rebuild(manifest)
    print('OK Creator Three.js r180: pinned bytes and MIT license verified')


if __name__ == '__main__':
    main()
