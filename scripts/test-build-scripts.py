#!/usr/bin/env python3
"""Portable, offline signing-input tests. No Apple credentials or dependencies."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("signing-profile.py")


class SigningPolicyTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            "UUID": "TEST-PROFILE-UUID", "TeamIdentifier": ["A1B2C3D4E5"],
            "ApplicationIdentifierPrefix": ["A1B2C3D4E5"],
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=30),
            "ProvisionedDevices": ["private-device-id-not-for-logs"],
            "Entitlements": {
                "application-identifier": "A1B2C3D4E5.com.example.probe",
                "com.apple.developer.team-identifier": "A1B2C3D4E5",
                "get-task-allow": False,
            },
        }

    def run_policy(self, profile=None, method="release-testing", bundle="com.example.probe", team="A1B2C3D4E5"):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            source, options, summary = [directory / name for name in ("profile.plist", "export.plist", "summary.json")]
            source.write_bytes(plistlib.dumps(profile if profile is not None else self.profile))
            environment = dict(os.environ, APPLE_TEAM_ID=team, BUNDLE_IDENTIFIER=bundle, EXPORT_METHOD=method)
            result = subprocess.run([sys.executable, str(SCRIPT), str(source), str(options), str(summary)], env=environment, capture_output=True, text=True)
            return result, plistlib.loads(options.read_bytes()) if options.exists() else None, json.loads(summary.read_text()) if summary.exists() else None

    def test_ad_hoc_profile_exports_exact_mapping_without_private_device_id(self):
        result, options, summary = self.run_policy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(options["provisioningProfiles"], {"com.example.probe": "TEST-PROFILE-UUID"})
        self.assertNotIn("private-device-id-not-for-logs", json.dumps(summary))
        self.assertFalse(summary["device_installation_verified"])

    def test_development_profile_for_debugging(self):
        self.profile["Entitlements"]["get-task-allow"] = True
        self.assertEqual(self.run_policy(method="debugging")[0].returncode, 0)
        self.assertNotEqual(self.run_policy()[0].returncode, 0)

    def test_app_store_profile_has_no_registered_devices(self):
        del self.profile["ProvisionedDevices"]
        self.assertEqual(self.run_policy(method="app-store-connect")[0].returncode, 0)
        self.assertNotEqual(self.run_policy()[0].returncode, 0)

    def test_expired_profile_fails(self):
        self.profile["ExpirationDate"] = datetime.datetime(2020, 1, 1)
        self.assertNotEqual(self.run_policy()[0].returncode, 0)

    def test_wrong_team_fails(self):
        self.assertNotEqual(self.run_policy(team="Z9Y8X7W6V5")[0].returncode, 0)

    def test_wrong_bundle_fails(self):
        self.assertNotEqual(self.run_policy(bundle="com.example.other")[0].returncode, 0)

    def test_wildcard_profile_fails(self):
        self.profile["Entitlements"]["application-identifier"] = "A1B2C3D4E5.*"
        self.assertNotEqual(self.run_policy()[0].returncode, 0)

    def test_unsupported_enterprise_profile_fails(self):
        self.profile["ProvisionsAllDevices"] = True
        self.assertNotEqual(self.run_policy()[0].returncode, 0)

    def test_unapproved_export_method_fails(self):
        self.assertNotEqual(self.run_policy(method="enterprise")[0].returncode, 0)

    def test_identifier_prefix_can_differ_from_team(self):
        self.profile["ApplicationIdentifierPrefix"] = ["F6G7H8I9J0"]
        self.profile["Entitlements"]["application-identifier"] = "F6G7H8I9J0.com.example.probe"
        self.assertEqual(self.run_policy()[0].returncode, 0)

    def test_malformed_uuid_fails(self):
        self.profile["UUID"] = "../../outside"
        self.assertNotEqual(self.run_policy()[0].returncode, 0)


if __name__ == "__main__":
    unittest.main()
