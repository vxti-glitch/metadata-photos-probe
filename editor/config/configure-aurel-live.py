#!/usr/bin/env python3
"""Stage public verification configuration only; never accepts a private key."""
import argparse
import base64
import os
from pathlib import Path
import plistlib

TEST_PIN = "r3CMZr6wV0FOjcIZ35lSABdfsZ7k2TOZr9ubg8Qqvg8="
ENDPOINT = "https://puxccjoofzlgxkssmfva.supabase.co/functions/v1/aurel-licenses-live/verify"


def configuration(pin):
    try:
        key = base64.b64decode(pin, validate=True)
    except (ValueError, TypeError):
        raise ValueError("A reviewed 32-byte public verification pin is required.") from None
    if len(key) != 32 or base64.b64encode(key).decode() != pin or pin == TEST_PIN or key == bytes(32):
        raise ValueError("The live public pin must be canonical, nonzero and distinct from the test pin.")
    return {"AurelLicenseEndpoint": ENDPOINT, "AurelLicenseIssuer": "aurel-archive-live",
            "AurelLicenseEnvironment": "live", "AurelLicensePublicKey": pin}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--check", action="store_true", help="Validate the existing configuration without modifying it")
    parser.add_argument("info_plist", type=Path)
    args = parser.parse_args()
    try:
        fields = configuration(os.environ.get("AUREL_LIVE_PUBLIC_KEY", ""))
    except ValueError as error:
        parser.error(str(error))
    # Validate completely before changing a caller-owned file.
    current = plistlib.loads(args.info_plist.read_bytes())
    if args.check:
        if any(current.get(name) != value for name, value in fields.items()):
            parser.error("The staged Info.plist does not match the reviewed live configuration.")
        return
    for name in ("AurelLicenseEndpoint", "AurelLicenseIssuer", "AurelLicenseEnvironment", "AurelLicensePublicKey"):
        current.pop(name, None)
    current.update(fields)
    args.info_plist.write_bytes(plistlib.dumps(current, sort_keys=False))


if __name__ == "__main__":
    main()
