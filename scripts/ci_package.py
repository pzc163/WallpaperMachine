#!/usr/bin/env python3
"""Package a CI release or an explicitly ad-hoc, non-publishing rehearsal."""
import argparse
from pathlib import Path
import subprocess
import sys

from lib.paths import ROOT


def package_command(*, ad_hoc=False, rehearsal=False, keychain=None):
    """An unsigned acceptance build must never enter the production release path."""
    if ad_hoc and not rehearsal:
        raise ValueError("Ad-hoc packaging is allowed only for a non-publishing rehearsal")
    command = [sys.executable, str(ROOT / "scripts/package.py"), "--configuration", "Release",
               "--require-deployment-target", "--require-notices"]
    if ad_hoc:
        return [*command, "--sign-identity", "-"]
    if not keychain:
        raise ValueError("Developer ID packaging requires the temporary signing keychain")
    return [*command, "--sign-identity", "Developer ID Application", "--notarize",
            "WallpaperMachine Notary", "--notary-keychain", str(keychain)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ad-hoc", action="store_true")
    parser.add_argument("--rehearsal", action="store_true")
    parser.add_argument("--keychain", type=Path)
    args = parser.parse_args(argv)
    try:
        command = package_command(ad_hoc=args.ad_hoc, rehearsal=args.rehearsal, keychain=args.keychain)
    except ValueError as error:
        parser.error(str(error))
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
