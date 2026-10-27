"""Offline configuration/build-staging checks; not an iOS compilation result."""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("live_config", ROOT / "configure-aurel-live.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ipa_spec = importlib.util.spec_from_file_location("live_ipa", ROOT / "verify-aurel-live-ipa.py")
ipa_module = importlib.util.module_from_spec(ipa_spec)
ipa_spec.loader.exec_module(ipa_module)


class LiveConfigurationTests(unittest.TestCase):
    def test_packaged_ipa_rejects_stale_configuration_and_ambiguous_main_app(self):
        pin = base64.b64encode(bytes(range(32))).decode()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.ipa"
            for fields in ({}, {"AurelLicenseIssuer": "aurel-archive-test"}):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(fields))
                with self.assertRaises(ValueError):
                    ipa_module.inspect_ipa(path, pin)
            with zipfile.ZipFile(path, "w") as archive:
                for name in ("Runner", "Unexpected"):
                    archive.writestr(f"Payload/{name}.app/Info.plist", plistlib.dumps(module.configuration(pin)))
            with self.assertRaises(ValueError):
                ipa_module.inspect_ipa(path, pin)

    def test_packaged_ipa_verifies_public_tuple_and_retains_device_acceptance_boundary(self):
        pin = base64.b64encode(bytes(range(32))).decode()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.ipa"
            fields = dict(module.configuration(pin), CFBundleShortVersionString="1.2.3", CFBundleVersion="45")
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps(fields))
            result = ipa_module.inspect_ipa(path, pin)
            self.assertEqual(result["license_configuration"], module.configuration(pin))
            self.assertEqual(result["version"], "1.2.3")
            self.assertFalse(result["physical_device_tested"])

    def test_live_build_rejects_missing_or_wrong_legal_review_before_platform_or_build(self):
        bash = Path("C:/Program Files/Git/bin/bash.exe")
        if not bash.exists():
            self.skipTest("Windows Git Bash not installed")
        for version in ("", "unreviewed"):
            result = subprocess.run([str(bash), str(ROOT / "build-aurel-live.sh"), "--live"],
                                    env=dict(os.environ, AUREL_LIVE_LEGAL_REVIEWED_VERSION=version),
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Release blocked", result.stderr)

    def test_rejects_missing_test_zero_noncanonical_and_private_material(self):
        for pin in ("", module.TEST_PIN, base64.b64encode(bytes(32)).decode(),
                    base64.b64encode(bytes(range(64))).decode(), "not-a-key", " " + base64.b64encode(bytes(range(32))).decode()):
            with self.subTest(pin_length=len(pin)), self.assertRaises(ValueError):
                module.configuration(pin)

    def test_public_config_is_exact_and_test_config_unchanged(self):
        # Synthetic public bytes are fixture data, never a real deployment pin.
        fields = module.configuration(base64.b64encode(bytes(range(32))).decode())
        self.assertEqual(fields["AurelLicenseIssuer"], "aurel-archive-live")
        self.assertEqual(fields["AurelLicenseEnvironment"], "live")
        self.assertEqual(fields["AurelLicenseEndpoint"], module.ENDPOINT)
        test = plistlib.loads((ROOT / "aurel-test-license.plist").read_bytes())
        self.assertEqual(test["AurelLicensePublicKey"], module.TEST_PIN)
        self.assertEqual(test["AurelLicenseIssuer"], "aurel-archive-test")

    def test_template_is_intentionally_invalid(self):
        template = plistlib.loads((ROOT / "aurel-live-license.plist.template").read_bytes())
        with self.assertRaises(ValueError):
            module.configuration(template["AurelLicensePublicKey"])

    def test_cli_failure_never_changes_info_and_live_is_explicit(self):
        with tempfile.TemporaryDirectory() as folder:
            info = Path(folder) / "Info.plist"
            original = plistlib.dumps({"CFBundleIdentifier": "com.example.fixture"})
            for arguments, pin in ((["--live"], ""), ([], base64.b64encode(bytes(range(32))).decode())):
                info.write_bytes(original)
                result = subprocess.run([sys.executable, str(ROOT / "configure-aurel-live.py"), *arguments, str(info)],
                                        env=dict(os.environ, AUREL_LIVE_PUBLIC_KEY=pin), capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(info.read_bytes(), original)

    def test_cli_preserves_unrelated_fields_and_replaces_mixed_aurel_values(self):
        with tempfile.TemporaryDirectory() as folder:
            info = Path(folder) / "Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.fixture", "AurelLicenseIssuer": "aurel-archive-test"}))
            result = subprocess.run([sys.executable, str(ROOT / "configure-aurel-live.py"), "--live", str(info)],
                                    env=dict(os.environ, AUREL_LIVE_PUBLIC_KEY=base64.b64encode(bytes(range(32))).decode()), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            fields = plistlib.loads(info.read_bytes())
            self.assertEqual(fields["CFBundleIdentifier"], "com.example.fixture")
            self.assertEqual(fields["AurelLicenseEnvironment"], "live")
            self.assertEqual(fields["AurelLicenseIssuer"], "aurel-archive-live")


if __name__ == "__main__":
    unittest.main()
