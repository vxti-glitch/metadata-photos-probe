#!/usr/bin/env python3
"""Record compile/packaging evidence, never label simulator success a device test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--mode", choices=("unsigned", "signed"), required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
build = root / "build"

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

artifacts = sorted(path for path in build.rglob("*") if path.is_file() and path.suffix in (".ipa", ".zip"))
manifest = {
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "workflow_run": os.environ.get("GITHUB_RUN_ID"),
    "mode": args.mode,
    "signed_ipa_exported": args.mode == "signed",
    "device_install_channel": os.environ.get("EXPORT_METHOD", "none; unsigned artifact"),
    "installation_verified": False,
    "physical_device_tested": False,
    "target_reported_by_user": "iPhone 15 Pro Max, iOS 27.2 (record actual version/build on device)",
    "attribution_requirement": "unverified; requires Photos UI and repeated physical-device observations",
    "toolchain_evidence": "evidence/toolchain.txt",
    "artifacts": [{"path": str(path.relative_to(build)), "bytes": path.stat().st_size, "sha256": sha256(path)} for path in artifacts],
}
(build / "evidence" / f"{args.mode}-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
