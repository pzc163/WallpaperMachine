#!/usr/bin/env python3
"""The CI signing boundary never silently downgrades a production release."""
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_package


class CIPackageTests(unittest.TestCase):
    def test_ad_hoc_acceptance_needs_no_credentials_or_notary(self):
        command = ci_package.package_command(ad_hoc=True, rehearsal=True)
        self.assertEqual(command[-2:], ["--sign-identity", "-"])
        self.assertNotIn("--notarize", command)
        self.assertNotIn("--notary-keychain", command)
        self.assertIn("--require-deployment-target", command)
        self.assertIn("--require-notices", command)

    def test_production_cannot_downgrade_to_ad_hoc(self):
        with self.assertRaises(ValueError):
            ci_package.package_command(ad_hoc=True)

    def test_missing_production_credentials_do_not_fall_back(self):
        with self.assertRaises(ValueError):
            ci_package.package_command()

    def test_notarized_build_retains_the_existing_signing_contract(self):
        command = ci_package.package_command(keychain=Path("/temporary/signing.keychain-db"))
        self.assertEqual(command[-6:], ["--sign-identity", "Developer ID Application", "--notarize",
                                       "WallpaperMachine Notary", "--notary-keychain", "/temporary/signing.keychain-db"])

    def test_rejected_cli_never_runs_packaging(self):
        with mock.patch.object(ci_package.subprocess, "run") as run:
            with self.assertRaises(SystemExit):
                ci_package.main(["--ad-hoc"])
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
