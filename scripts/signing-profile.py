#!/usr/bin/env python3
"""Validate an explicit manual profile without exposing device IDs or key material."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
team = os.environ["APPLE_TEAM_ID"]
bundle = os.environ["BUNDLE_IDENTIFIER"]
method = os.environ["EXPORT_METHOD"]
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    sys.exit("APPLE_TEAM_ID must be the 10-character team identifier.")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
    sys.exit("BUNDLE_IDENTIFIER must be a valid explicit bundle identifier.")
if method not in ("release-testing", "debugging", "app-store-connect"):
    sys.exit("Unsupported export method.")
if team not in profile.get("TeamIdentifier", []):
    sys.exit("Provisioning profile belongs to a different Apple team.")
entitlements = profile["Entitlements"]
prefixes = profile.get("ApplicationIdentifierPrefix", [])
expected_ids = [f"{prefix}.{bundle}" for prefix in prefixes]
if entitlements.get("application-identifier") not in expected_ids:
    sys.exit("Use an explicit provisioning profile matching BUNDLE_IDENTIFIER.")
if entitlements.get("com.apple.developer.team-identifier") != team:
    sys.exit("Profile entitlement team does not match APPLE_TEAM_ID.")
expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
if expires <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("Provisioning profile is expired.")
if profile.get("ProvisionsAllDevices"):
    sys.exit("Enterprise all-device profiles are outside this prototype signing scope.")
has_devices = bool(profile.get("ProvisionedDevices"))
debuggable = bool(entitlements.get("get-task-allow", False))
if method == "release-testing" and (not has_devices or debuggable):
    sys.exit("release-testing requires an ad hoc profile with registered devices and get-task-allow false.")
if method == "debugging" and (not has_devices or not debuggable):
    sys.exit("debugging requires a development profile with registered devices.")
if method == "app-store-connect" and (has_devices or debuggable):
    sys.exit("app-store-connect requires an App Store distribution profile.")
uuid = profile["UUID"]
if not re.fullmatch(r"[A-Za-z0-9-]+", uuid):
    sys.exit("Invalid provisioning profile UUID.")
options = {
    "method": method,
    "teamID": team,
    "signingStyle": "manual",
    "provisioningProfiles": {bundle: uuid},
    "manageAppVersionAndBuildNumber": False,
    "stripSwiftSymbols": True,
}
Path(sys.argv[2]).write_bytes(plistlib.dumps(options))
Path(sys.argv[3]).write_text(json.dumps({
    "team": team, "bundle": bundle, "profile_uuid": uuid,
    "profile_expires_utc": expires.isoformat(), "export_method": method,
    "registered_device_count": len(profile.get("ProvisionedDevices", [])),
    "device_installation_verified": False,
}, indent=2) + "\n", encoding="utf-8")
print(uuid)
