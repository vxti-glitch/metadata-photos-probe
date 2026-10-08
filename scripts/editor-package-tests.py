#!/usr/bin/env python3
"""Portable tests of release architecture, identity and version validation."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("editor_package", Path(__file__).with_name("editor-package.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
ARM64 = 0x0100000C
X64 = 0x01000007


class EditorPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Runner.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": package.BUNDLE_ID, "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "4", "CFBundleExecutable": "Runner", "MinimumOSVersion": "17.0",
            "DTPlatformName": "iphoneos",
            "NSPhotoLibraryUsageDescription": "Test description",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        }
        self.write_info()
        self.binaries = [self.app / "Runner", self.app / "Frameworks/Flutter.framework/Flutter",
                         self.app / "Frameworks/App.framework/App"]
        for binary in self.binaries:
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(self.device_binary())

    @staticmethod
    def device_binary(platform=2):
        header = b"\xcf\xfa\xed\xfe" + struct.pack("<IIIIIII", ARM64, 0, 2, 1, 24, 0, 0)
        return header + struct.pack("<IIIIII", 0x32, 24, platform, 0x110000, 0x1A0200, 0)

    def write_info(self):
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def inspect(self, signature=None):
        signature = signature or subprocess.CompletedProcess([], 1, "", "code object is not signed at all")
        with patch.object(package, "expected_version", return_value=("0.3.0", "4")), \
                patch.object(package.subprocess, "run", return_value=signature):
            return package.inspect_app(self.app)

    def test_unsigned_device_archive_records_framework_hashes(self):
        result = self.inspect()
        self.assertEqual(result["app_signature"], "unsigned")
        self.assertFalse(result["provisioning_profile_embedded"])
        self.assertEqual(set(result["framework_binaries"]), {"app", "Flutter.framework", "App.framework"})
        self.assertEqual(len(result["framework_binaries"]["app"]["sha256"]), 64)

    def test_simulator_framework_rejected(self):
        self.binaries[1].write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", X64) + bytes(24))
        with self.assertRaisesRegex(ValueError, "device-only arm64"):
            self.inspect()

    def test_arm64_simulator_framework_rejected(self):
        self.binaries[1].write_bytes(self.device_binary(platform=7))
        with self.assertRaisesRegex(ValueError, "iOS device platform"):
            self.inspect()

    def test_provisioning_profile_rejected(self):
        (self.app / "embedded.mobileprovision").write_bytes(b"synthetic profile")
        with self.assertRaisesRegex(ValueError, "provisioning profile"):
            self.inspect()

    def test_unexpected_signing_identity_rejected(self):
        signed = subprocess.CompletedProcess([], 0, "", "Authority=Apple Development\nTeamIdentifier=ABCD123456\n")
        with self.assertRaisesRegex(ValueError, "identity-signed"):
            self.inspect(signed)

    def test_ad_hoc_signature_is_reported_as_needing_resigning(self):
        signature = subprocess.CompletedProcess([], 0, "", "Signature=adhoc\nTeamIdentifier=not set\n")
        self.assertIn("must re-sign", self.inspect(signature)["app_signature"])

    def test_wrong_version_or_missing_photos_reason_rejected(self):
        self.info["CFBundleVersion"] = "99"
        self.write_info()
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            self.inspect()
        self.info["CFBundleVersion"] = "4"
        del self.info["NSPhotoLibraryUsageDescription"]
        self.write_info()
        with self.assertRaisesRegex(ValueError, "Photos"):
            self.inspect()

    def test_missing_flutter_engine_rejected(self):
        self.binaries[1].unlink()
        with self.assertRaisesRegex(ValueError, "Flutter.framework"):
            self.inspect()

    def test_malformed_or_truncated_macho_rejected(self):
        self.binaries[0].write_bytes(b"\xcf\xfa")
        with self.assertRaisesRegex(ValueError, "Truncated"):
            package.macho_architectures(self.binaries[0])
        self.binaries[0].write_bytes(b"\xca\xfe\xba\xbe" + struct.pack(">I", 99))
        with self.assertRaisesRegex(ValueError, "Invalid fat"):
            package.macho_architectures(self.binaries[0])

    def test_fat_macho_returns_all_cpu_types_for_rejection(self):
        payload = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        payload += struct.pack(">IIIII", ARM64, 0, 4096, 64, 12)
        payload += struct.pack(">IIIII", X64, 0, 8192, 64, 12)
        self.binaries[0].write_bytes(payload)
        self.assertEqual(package.macho_architectures(self.binaries[0]), [ARM64, X64])
        with self.assertRaisesRegex(ValueError, "device-only arm64"):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
