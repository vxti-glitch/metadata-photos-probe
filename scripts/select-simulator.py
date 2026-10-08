#!/usr/bin/env python3
"""Choose an available iPhone, never mistake it for the physical target device."""
import json
import subprocess
import sys

state = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
candidates = []
for runtime, devices in state["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((runtime, device))
if not candidates:
    sys.exit("No available iPhone simulator. Install a compatible runtime; do not skip tests.")
# Prefer the intended model if installed; otherwise test public API contracts on an available model.
candidates.sort(key=lambda pair: (pair[1]["name"] == "iPhone 15 Pro Max", pair[0], pair[1]["name"]), reverse=True)
runtime, device = candidates[0]
print(f'Simulator only: {device["name"]}, {runtime}, {device["udid"]}', file=sys.stderr)
print(f'platform=iOS Simulator,id={device["udid"]}')
