#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Keychain simulator diagnosis requires macOS/Xcode.' >&2; exit 1; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/build/keychain-evidence"
task_work="$(mktemp -d -t aurel-keychain.XXXXXX)"
trap 'rm -rf "$task_work"' EXIT
mkdir -p "$task_output"
if [[ -d /Applications/Xcode_26.2.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
fi
task_destination="$(python3 "$task_root/scripts/select-simulator.py" 2>"$task_output/simulator.txt")"
task_simulator="${task_destination##*id=}"
if ! xcrun simctl list devices booted | grep -Fq "$task_simulator"; then
  xcrun simctl boot "$task_simulator"
fi
xcrun simctl bootstatus "$task_simulator" -b
task_app="$task_work/KeychainProbe.app"
mkdir -p "$task_app"
python3 - "$task_app/Info.plist" "$task_work/entitlements.plist" <<'PY'
from pathlib import Path
import plistlib,sys
identifier='com.aurel.ci.keychain-probe'
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleExecutable':'KeychainProbe','CFBundleName':'KeychainProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'15.0','LSRequiresIPhoneOS':True,'UILaunchScreen':{}}))
Path(sys.argv[2]).write_bytes(plistlib.dumps({'application-identifier':'CIKEYCHAIN.'+identifier,'keychain-access-groups':['CIKEYCHAIN.'+identifier]}))
PY
task_arch="$(uname -m)"
[[ "$task_arch" == arm64 || "$task_arch" == x86_64 ]] || exit 1
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target "$task_arch-apple-ios15.0-simulator" \
  "$task_root/editor/ios/Runner/ZlarpLicenseService.swift" "$task_root/editor/config/KeychainProbe.swift" \
  -o "$task_app/KeychainProbe"
codesign --remove-signature "$task_app" 2>/dev/null || true
for task_mode in unsigned signed; do
  if [[ "$task_mode" == signed ]]; then
    codesign --force --sign - --entitlements "$task_work/entitlements.plist" "$task_app"
  fi
  codesign --display --entitlements :- "$task_app" > "$task_output/$task_mode-entitlements.plist" 2> "$task_output/$task_mode-signature.txt" || true
  xcrun simctl install "$task_simulator" "$task_app"
  task_container="$(xcrun simctl get_app_container "$task_simulator" com.aurel.ci.keychain-probe data)"
  rm -f "$task_container/Documents/keychain-probe.json"
  xcrun simctl launch "$task_simulator" com.aurel.ci.keychain-probe
  for task_attempt in $(seq 1 20); do
    [[ -f "$task_container/Documents/keychain-probe.json" ]] && break
    sleep 1
  done
  [[ -f "$task_container/Documents/keychain-probe.json" ]] || { printf '%s\n' 'Probe did not write bounded diagnostic evidence.' >&2; exit 1; }
  cp "$task_container/Documents/keychain-probe.json" "$task_output/$task_mode-result.json"
  cat "$task_output/$task_mode-result.json"
  xcrun simctl terminate "$task_simulator" com.aurel.ci.keychain-probe
done
python3 - "$task_output" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
unsigned=json.loads((root/'unsigned-result.json').read_text())
signed=json.loads((root/'signed-result.json').read_text())
result={'unsigned':unsigned,'ad_hoc_simulator_signed':signed,'production_storage_implementation':'ZlarpKeychainStorage','physical_device_tested':False,'production_ipa_modified':False}
(root/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
if not signed.get('passed'):
    raise SystemExit('Signed simulator synthetic Keychain round-trip failed; inspect measured OSStatus.')
PY
