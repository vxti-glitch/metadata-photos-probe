#!/usr/bin/env python3
"""Portable tests of release architecture, identity and version validation."""
import importlib.util
import json
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
        self.catalog_source = Path(self.temporary.name) / "editor/assets/camera_profiles.json"
        self.catalog_packaged = self.app / "Frameworks/App.framework/flutter_assets/assets/camera_profiles.json"
        self.catalog = {"schemaVersion": 1, "revision": "2026-10-08",
                        "profiles": [{"id": "synthetic-camera", "cameras": [{"id": "main"}]}]}
        self.write_catalog()
        self.info = {
            "CFBundleIdentifier": package.BUNDLE_ID, "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "4", "CFBundleExecutable": "Runner", "MinimumOSVersion": "17.0",
            "CFBundleDisplayName": package.DISPLAY_NAME, "CFBundleName": package.BUNDLE_NAME,
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
    def device_binary(platform=2, cpu=ARM64, subtype=0):
        header = b"\xcf\xfa\xed\xfe" + struct.pack("<IIIIIII", cpu, subtype, 2, 1, 24, 0, 0)
        return header + struct.pack("<IIIIII", 0x32, 24, platform, 0x110000, 0x1A0200, 0)

    @staticmethod
    def fat_binary(slices, wide=False, endian=">"):
        magic = {(">", False): b"\xca\xfe\xba\xbe", ("<", False): b"\xbe\xba\xfe\xca",
                 (">", True): b"\xca\xfe\xba\xbf", ("<", True): b"\xbf\xba\xfe\xca"}[endian, wide]
        width = 32 if wide else 20
        data = bytearray(128 * (len(slices) + 1))
        data[:8] = magic + struct.pack(endian + "I", len(slices))
        for index, payload in enumerate(slices):
            offset = 128 * (index + 1)
            cpu, subtype = struct.unpack_from("<II", payload, 4)
            entry = struct.pack(endian + ("IIQQII" if wide else "IIIII"),
                                cpu, subtype, offset, len(payload), 7, *([0] if wide else []))
            data[8 + index * width:8 + (index + 1) * width] = entry
            data[offset:offset + len(payload)] = payload
        return bytes(data)

    def write_info(self):
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def write_catalog(self):
        payload = (json.dumps(self.catalog) + "\n").encode("utf-8")
        for location in (self.catalog_source, self.catalog_packaged):
            location.parent.mkdir(parents=True, exist_ok=True)
            location.write_bytes(payload)

    def inspect(self, signature=None):
        signature = signature or subprocess.CompletedProcess([], 1, "", "code object is not signed at all")
        with patch.object(package, "expected_version", return_value=("0.3.0", "4")), \
                patch.object(package, "ROOT", Path(self.temporary.name)), \
                patch.object(package.subprocess, "run", return_value=signature):
            return package.inspect_app(self.app)

    def test_unsigned_device_archive_records_framework_hashes(self):
        result = self.inspect()
        self.assertEqual(result["app_signature"], "unsigned")
        self.assertFalse(result["provisioning_profile_embedded"])
        self.assertEqual(set(result["framework_binaries"]), {"app", "Flutter.framework", "App.framework"})
        self.assertEqual(len(result["framework_binaries"]["app"]["sha256"]), 64)
        self.assertEqual(result["camera_catalog"]["profiles"], 1)
        self.assertEqual(result["camera_catalog"]["cameras"], 1)
        self.assertEqual(result["camera_catalog"]["sha256"], package.sha256(self.catalog_source))

    def test_missing_or_stale_packaged_catalog_rejected(self):
        self.catalog_packaged.unlink()
        with self.assertRaisesRegex(ValueError, "catalog is missing"):
            self.inspect()
        self.write_catalog()
        self.catalog_packaged.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "catalog differs"):
            self.inspect()

    def test_empty_duplicate_and_unknown_catalogs_rejected(self):
        for change, error in [({"profiles": []}, "profile list"),
                              ({"schemaVersion": 99}, "schema"),
                              ({"revision": ""}, "revision"),
                              ({"profiles": [{"id": "duplicate", "cameras": [{}]}] * 2}, "duplicate")]:
            with self.subTest(change=change):
                original = dict(self.catalog)
                self.catalog.update(change)
                self.write_catalog()
                with self.assertRaisesRegex(ValueError, error):
                    self.inspect()
                self.catalog = original

    def test_oversized_catalog_rejected_before_reading(self):
        self.catalog_packaged.write_bytes(b" " * (2 * 1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, "size bound"):
            self.inspect()

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

    def test_old_branding_rejected_even_when_identifier_and_version_match(self):
        for key, old_value in [("CFBundleDisplayName", "Zlarp Metadata"),
                               ("CFBundleName", "zlarp_metadata_editor"),
                               ("CFBundleDisplayName", "Framevell"), ("CFBundleName", "framevell")]:
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = old_value
                self.write_info()
                with self.assertRaisesRegex(ValueError, key):
                    self.inspect()
                self.info[key] = original
                self.write_info()
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
        payload = self.fat_binary([self.device_binary(), self.device_binary(platform=7, cpu=X64)])
        self.binaries[0].write_bytes(payload)
        self.assertEqual(package.macho_architectures(self.binaries[0]), [ARM64, X64])
        with self.assertRaisesRegex(ValueError, "device-only arm64"):
            self.inspect()

    def test_fat_device_framework_supports_both_widths_and_table_endianness(self):
        for wide in [False, True]:
            for endian in [">", "<"]:
                for count in [1, 2]:
                    with self.subTest(wide=wide, endian=endian, count=count):
                        payloads = [self.device_binary(subtype=index) for index in range(count)]
                        self.binaries[2].write_bytes(self.fat_binary(payloads, wide=wide, endian=endian))
                        result = self.inspect()
                        self.assertEqual(result["framework_binaries"]["App.framework"]["platform"], "iOS device")
                        self.assertEqual(result["framework_binaries"]["App.framework"]["slice_count"], count)

    def test_fat_arm64_device_and_simulator_slices_are_rejected(self):
        self.binaries[2].write_bytes(self.fat_binary([self.device_binary(), self.device_binary(platform=7)]))
        with self.assertRaisesRegex(ValueError, "iOS device platform"):
            self.inspect()

    def test_fat_slice_outside_file_and_overlap_are_rejected(self):
        for wide in [False, True]:
            with self.subTest(wide=wide):
                data = bytearray(self.fat_binary([self.device_binary()], wide=wide))
                struct.pack_into(">Q" if wide else ">I", data, 16, (1 << 63) if wide else len(data) + 128)
                self.binaries[2].write_bytes(data)
                with self.assertRaisesRegex(ValueError, "slice exceeds file bounds"):
                    self.inspect()
        data = bytearray(self.fat_binary([self.device_binary(), self.device_binary()]))
        struct.pack_into(">I", data, 36, 128)
        self.binaries[2].write_bytes(data)
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            self.inspect()

    def test_fat_declared_cpu_must_match_actual_slice(self):
        data = bytearray(self.fat_binary([self.device_binary()]))
        struct.pack_into(">I", data, 8, X64)
        self.binaries[2].write_bytes(data)
        with self.assertRaisesRegex(ValueError, "CPU declaration differs"):
            self.inspect()

    def test_load_commands_cannot_read_outside_fat_slice(self):
        data = bytearray(self.fat_binary([self.device_binary(), self.device_binary()]))
        struct.pack_into(">I", data, 20, 32)
        self.binaries[2].write_bytes(data)
        with self.assertRaisesRegex(ValueError, "load commands exceed slice bounds"):
            self.inspect()

    def test_malformed_platform_tool_table_is_rejected(self):
        data = bytearray(self.device_binary())
        struct.pack_into("<I", data, 52, 99)
        self.binaries[2].write_bytes(data)
        with self.assertRaisesRegex(ValueError, "build-tool table"):
            self.inspect()

    def test_document_sharing_and_file_provider_flags_enabled(self):
        info_plist_path = package.ROOT / "editor/ios/Runner/Info.plist"
        with info_plist_path.open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertTrue(plist.get("UIFileSharingEnabled"), "UIFileSharingEnabled must be true for Files app visibility")
        self.assertTrue(plist.get("LSSupportsOpeningDocumentsInPlace"), "LSSupportsOpeningDocumentsInPlace must be true")

    def test_mark_svg_and_brand_theme_color(self):
        svg_path = package.ROOT / "editor/branding/mark.svg"
        svg_content = svg_path.read_text(encoding="utf-8")
        self.assertIn("#9CB5FF", svg_content.upper())
        self.assertNotIn("#84E4C7", svg_content.upper(), "Legacy green theme must not be in mark.svg")

    def test_native_bridge_and_store_contracts(self):
        bridge_swift = (package.ROOT / "editor/ios/Runner/NativeMediaBridge.swift").read_text(encoding="utf-8")
        self.assertIn('case "shareFiles":', bridge_swift)
        self.assertIn('case "shareFilesBatch":', bridge_swift)
        store_swift = (package.ROOT / "editor/ios/Runner/NativeSessionStore.swift").read_text(encoding="utf-8")
        self.assertIn('Processed Media', store_swift)
        self.assertIn('autoExportFolder', store_swift)


if __name__ == "__main__":
    unittest.main()

