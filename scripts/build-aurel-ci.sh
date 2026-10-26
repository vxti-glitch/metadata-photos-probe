#!/bin/bash
# Public test provider settings only. No private signing key is in this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
original="$(mktemp -t aurel-ci-info.XXXXXX)"
cp editor/ios/Runner/Info.plist "$original"
restore_info() { cp "$original" editor/ios/Runner/Info.plist; rm -f "$original"; }
trap restore_info EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/libexec/PlistBuddy -c "Merge editor/config/aurel-test-license.plist" editor/ios/Runner/Info.plist
bash scripts/build-editor-macos.sh
python3 - <<'PY'
import json,plistlib
from pathlib import Path
expected=plistlib.loads(Path('editor/config/aurel-test-license.plist').read_bytes())
path=Path('editor/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Info.plist')
actual=plistlib.loads(path.read_bytes())
for key,value in expected.items():
    assert actual.get(key)==value, f'Wrong packaged provider setting: {key}'
Path('build/editor/evidence/aurel-provider.json').write_text(json.dumps({'environment':'test','packaged_settings_match':True,'public_configuration':expected},indent=2))
print('Packaged Aurel sandbox issuer, endpoint and public pin match.')
PY
