#!/bin/bash
# macOS only. Public verification pin; no signing secret belongs in this file.
set -euo pipefail
cd "$(dirname "$0")/.."
original="$(mktemp -t aurel-info.XXXXXX)"
cp ios/Runner/Info.plist "$original"
restore_info() { cp "$original" ios/Runner/Info.plist; rm -f "$original"; }
trap restore_info EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/libexec/PlistBuddy -c "Merge config/aurel-test-license.plist" ios/Runner/Info.plist
flutter build ios --release --no-codesign
