#!/usr/bin/env python3
"""Verify the built IPA's public live tuple without extracting archive contents."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import zipfile

spec = importlib.util.spec_from_file_location("live_config", Path(__file__).with_name("configure-aurel-live.py"))
live_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_config)


def inspect_ipa(path, pin):
    expected = live_config.configuration(pin)
    with zipfile.ZipFile(path) as archive:
        candidates = [entry for entry in archive.infolist()
                      if entry.filename.startswith("Payload/") and entry.filename.endswith(".app/Info.plist")
                      and entry.filename.count("/") == 2]
        if len(candidates) != 1 or candidates[0].file_size > 1024 * 1024:
            raise ValueError("Expected one bounded main app Info.plist in the production IPA.")
        info = plistlib.loads(archive.read(candidates[0]))
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("Packaged IPA does not contain the exact reviewed live license configuration.")
    return {"license_configuration": expected, "bundle_identifier": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"), "build_number": info.get("CFBundleVersion"),
            "installation_verified": False, "physical_device_tested": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    candidates = list(args.output_directory.glob("*.ipa"))
    if len(candidates) != 1:
        parser.error("Expected exactly one compiled IPA in the build output directory.")
    evidence = inspect_ipa(candidates[0], os.environ.get("AUREL_LIVE_PUBLIC_KEY", ""))
    destination = args.output_directory / "evidence/aurel-live-package.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
