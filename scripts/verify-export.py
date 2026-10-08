#!/usr/bin/env python3
"""Check the exported identity and profile; installation still needs the device."""
import datetime
import os
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
entitlements = plistlib.loads(Path(sys.argv[2]).read_bytes())
profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")]))
team = os.environ["APPLE_TEAM_ID"]
bundle = os.environ["BUNDLE_IDENTIFIER"]
if info["CFBundleIdentifier"] != bundle:
    sys.exit("Exported bundle identity mismatch.")
if entitlements.get("com.apple.developer.team-identifier") != team:
    sys.exit("Exported signing entitlement team mismatch.")
if team not in profile.get("TeamIdentifier", []):
    sys.exit("Exported provisioning profile team mismatch.")
expected_id = profile["Entitlements"]["application-identifier"]
if entitlements.get("application-identifier") != expected_id or not expected_id.endswith("." + bundle):
    sys.exit("Exported signing application identifier mismatch.")
if profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("Exported provisioning profile expired.")
if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
    sys.exit("Export is not an iPhoneOS device application.")
print("IPA signing, embedded profile and bundle identity verified; installation and Photos behavior remain untested.")
