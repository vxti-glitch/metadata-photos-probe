#!/usr/bin/env python3
"""Validate and package a Flutter arm64 archive; never imply an unsigned IPA installs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.vxtiglitch.metadataeditor"
DISPLAY_NAME = "Metadata Editor"
BUNDLE_NAME = "metadata_editor"
FLUTTER_COMMIT = "5fc346839b5d0eef006ed8404392afb4dfae428d"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def macho_slices(path):
    """Read bounded thin/fat slice locations and verify their declared CPU headers."""
    file_bytes = path.stat().st_size
    with path.open("rb") as stream:
        data = stream.read(4096)
    if len(data) < 8:
        raise ValueError(f"Truncated Mach-O: {path.name}")
    magic = data[:4]
    thin_formats = {
        b"\xcf\xfa\xed\xfe": ("<", 32), b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xcf": (">", 32), b"\xfe\xed\xfa\xce": (">", 28),
    }
    if magic in thin_formats:
        endian, width = thin_formats[magic]
        if len(data) < width:
            raise ValueError(f"Truncated Mach-O header: {path.name}")
        cpu, subtype = struct.unpack_from(endian + "II", data, 4)
        return [{"offset": 0, "size": file_bytes, "cpu": cpu, "subtype": subtype}]
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32),
    }
    if magic not in fat_formats:
        raise ValueError(f"Not a Mach-O executable: {path.name}")
    endian, width = fat_formats[magic]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    if not 1 <= count <= 64 or 8 + count * width > len(data):
        raise ValueError(f"Invalid fat Mach-O table: {path.name}")
    table_end = 8 + count * width
    slices = []
    for index in range(count):
        position = 8 + index * width
        if width == 20:
            cpu, subtype, offset, size, alignment = struct.unpack_from(endian + "IIIII", data, position)
        else:
            cpu, subtype, offset, size, alignment, reserved = struct.unpack_from(endian + "IIQQII", data, position)
            if reserved != 0:
                raise ValueError(f"Invalid fat Mach-O reserved field: {path.name}")
        if offset < table_end or size < 28 or offset + size > file_bytes:
            raise ValueError(f"Fat Mach-O slice exceeds file bounds: {path.name}")
        if alignment > 31 or offset % (1 << alignment):
            raise ValueError(f"Invalid fat Mach-O slice alignment: {path.name}")
        slices.append({"offset": offset, "size": size, "cpu": cpu, "subtype": subtype})
    ordered = sorted(slices, key=lambda entry: entry["offset"])
    if any(left["offset"] + left["size"] > right["offset"] for left, right in zip(ordered, ordered[1:])):
        raise ValueError(f"Overlapping fat Mach-O slices: {path.name}")
    with path.open("rb") as stream:
        for entry in slices:
            stream.seek(entry["offset"])
            header = stream.read(min(32, entry["size"]))
            if header[:4] not in thin_formats:
                raise ValueError(f"Fat Mach-O slice has no thin header: {path.name}")
            thin_endian, header_size = thin_formats[header[:4]]
            if len(header) < header_size:
                raise ValueError(f"Truncated fat Mach-O slice header: {path.name}")
            cpu, subtype = struct.unpack_from(thin_endian + "II", header, 4)
            if cpu != entry["cpu"] or subtype != entry["subtype"]:
                raise ValueError(f"Fat Mach-O CPU declaration differs from slice: {path.name}")
    return slices


def macho_architectures(path):
    """Inspect every bounded thin/fat CPU header without trusting filenames."""
    return [entry["cpu"] for entry in macho_slices(path)]


def expected_version():
    text = (ROOT / "editor/pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", text)
    if not match:
        raise ValueError("Editor version must contain explicit semantic version and build number.")
    return match.groups()


def macho_device_platform(path):
    """Reject ARM64 simulator binaries, which have the same CPU type as device binaries."""
    slices = macho_slices(path)
    with path.open("rb") as stream:
        for entry in slices:
            stream.seek(entry["offset"])
            header = stream.read(32)
            if entry["cpu"] != 0x0100000C or entry["size"] < 32 or header[:4] != b"\xcf\xfa\xed\xfe":
                raise ValueError(f"Expected little-endian arm64 Mach-O slice: {path.name}")
            command_count, command_bytes = struct.unpack_from("<II", header, 16)
            if not 1 <= command_count <= 4096 or not 8 <= command_bytes <= 16 * 1024 * 1024:
                raise ValueError(f"Unqualified Mach-O load commands: {path.name}")
            if command_bytes > entry["size"] - 32:
                raise ValueError(f"Mach-O load commands exceed slice bounds: {path.name}")
            commands = stream.read(command_bytes)
            validate_device_commands(commands, command_count, command_bytes, path.name)
    return "iOS device"


def validate_device_commands(commands, command_count, command_bytes, name):
    if len(commands) != command_bytes:
        raise ValueError(f"Truncated Mach-O load commands: {name}")
    platforms = []
    cursor = 0
    for _ in range(command_count):
        if cursor + 8 > len(commands):
            raise ValueError(f"Truncated Mach-O command header: {name}")
        kind, size = struct.unpack_from("<II", commands, cursor)
        if size < 8 or size % 8 or cursor + size > len(commands):
            raise ValueError(f"Invalid Mach-O command size: {name}")
        if kind == 0x32:  # LC_BUILD_VERSION; platform 2 is iOS, 7 is iOS Simulator.
            if size < 24:
                raise ValueError(f"Truncated platform command: {name}")
            tool_count = struct.unpack_from("<I", commands, cursor + 20)[0]
            if size != 24 + tool_count * 8:
                raise ValueError(f"Invalid Mach-O build-tool table: {name}")
            platforms.append(struct.unpack_from("<I", commands, cursor + 8)[0])
        elif kind == 0x25:  # LC_VERSION_MIN_IPHONEOS on an arm64 legacy device binary.
            if size < 16:
                raise ValueError(f"Truncated legacy iOS command: {name}")
            platforms.append(2)
        elif kind in (0x24, 0x2F, 0x30):
            # Other legacy minimum-platform commands cannot coexist with an iOS qualification.
            platforms.append(-1)
        cursor += size
    if cursor != len(commands) or platforms != [2]:
        raise ValueError(f"{name} is not qualified for the iOS device platform.")


def inspect_app(app):
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version, build = expected_version()
    required = {
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "CFBundleDisplayName": DISPLAY_NAME, "CFBundleName": BUNDLE_NAME,
    }
    for key, value in required.items():
        if info.get(key) != value:
            raise ValueError(f"Archive {key} differs from committed configuration.")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("Archive does not declare the iOS device platform.")
    if not info.get("NSPhotoLibraryUsageDescription"):
        raise ValueError("Archive is missing the Photos read permission explanation.")
    if not info.get("UIApplicationSceneManifest"):
        raise ValueError("Flutter UIScene configuration is missing.")
    if list(app.rglob("embedded.mobileprovision")):
        raise ValueError("Unsigned archive unexpectedly contains a provisioning profile.")
    executables = {
        "app": app / info["CFBundleExecutable"],
        "Flutter.framework": app / "Frameworks/Flutter.framework/Flutter",
        "App.framework": app / "Frameworks/App.framework/App",
    }
    binaries = {}
    arm64 = 0x0100000C
    for name, executable in executables.items():
        if not executable.is_file():
            raise ValueError(f"Archive is missing {name} executable.")
        architectures = macho_architectures(executable)
        if arm64 not in architectures or any(cpu != arm64 for cpu in architectures):
            raise ValueError(f"{name} is not a device-only arm64 binary.")
        platform = macho_device_platform(executable)
        binaries[name] = {"architectures": ["arm64"], "slice_count": len(architectures),
                          "platform": platform, "bytes": executable.stat().st_size,
                          "sha256": sha256(executable)}
    signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)],
                               capture_output=True, text=True, check=False)
    signature_text = signature.stderr + signature.stdout
    # Apple toolchains may generate ad-hoc signatures. An identity/profile must not be injected.
    if "Authority=" in signature_text or re.search(r"TeamIdentifier=(?!not set)[^\s]+", signature_text):
        raise ValueError("An identity-signed app was produced in the unsigned build path.")
    return {
        "bundle_identifier": info["CFBundleIdentifier"], "version": version, "build_number": build,
        "display_name": info["CFBundleDisplayName"], "bundle_name": info["CFBundleName"],
        "minimum_os": info.get("MinimumOSVersion"),
        "sdk": info.get("DTSDKName"), "platform": info.get("DTPlatformName"),
        "xcode_build": info.get("DTXcodeBuild"), "framework_binaries": binaries,
        "app_signature": "ad-hoc; must re-sign for device" if signature.returncode == 0 else "unsigned",
        "provisioning_profile_embedded": False,
    }


def make_manifest(output):
    archive_evidence = output / "evidence/archive-inspection.json"
    if not archive_evidence.is_file():
        raise ValueError("Successful archive inspection is required before producing a release manifest.")
    flutter = json.loads((output / "evidence/flutter-version.json").read_text(encoding="utf-8"))
    if flutter.get("frameworkRevision") != FLUTTER_COMMIT or flutter.get("frameworkVersion") != "3.47.6":
        raise ValueError("Build used an unexpected Flutter SDK revision.")
    artifacts = sorted(path for path in output.iterdir() if path.suffix in (".ipa", ".zip"))
    manifest = {
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "workflow_run": os.environ.get("GITHUB_RUN_ID"), "artifact_mode": "unsigned; requires independent signing",
        "signed_ipa_exported": False, "installation_verified": False, "physical_device_tested": False,
        "simulator_scope": "Native session tests and app launch only; no physical Photos attribution conclusion.",
        "export_workflow": "Files, then user-operated Safari/iCloud Photos upload",
        "flutter": flutter, "archive": json.loads(archive_evidence.read_text(encoding="utf-8")),
        "artifacts": [{"path": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)} for path in artifacts],
    }
    (output / "unsigned-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive")
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest-only", action="store_true")
    args = parser.parse_args()
    output = (ROOT / args.output).resolve()
    if not output.is_relative_to(ROOT / "build"):
        parser.error("Output must stay within the repository build directory.")
    output.mkdir(parents=True, exist_ok=True)
    if args.manifest_only:
        make_manifest(output)
        return
    if not args.archive:
        parser.error("--archive is required unless --manifest-only is selected.")
    archive = (ROOT / args.archive).resolve()
    applications = list((archive / "Products/Applications").glob("*.app"))
    if len(applications) != 1:
        raise ValueError("Expected exactly one archived Flutter application.")
    app = applications[0]
    inspection = inspect_app(app)
    (output / "evidence").mkdir(exist_ok=True)
    (output / "evidence/archive-inspection.json").write_text(json.dumps(inspection, indent=2) + "\n", encoding="utf-8")
    ipa = output / "Metadata-Editor-UNSIGNED-NOT-INSTALLABLE.ipa"
    archive_zip = output / "Metadata-Editor-xcarchive.zip"
    if ipa.exists() or archive_zip.exists():
        raise ValueError("Build outputs already exist; use a fresh build directory.")
    with tempfile.TemporaryDirectory(prefix="editor-payload-", dir=output) as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(payload), str(ipa)], check=True)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(archive), str(archive_zip)], check=True)
    print(json.dumps(inspection, indent=2))


if __name__ == "__main__":
    main()
