#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'iOS compilation requires macOS/Xcode.' >&2; exit 1; }
mkdir -p build/evidence
{
  date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
  git rev-parse HEAD
  sw_vers
  uname -m
  xcode-select -p
  xcodebuild -version
  xcodebuild -showsdks
  swift --version
  xcrun simctl list devices available
} > build/evidence/toolchain.txt 2>&1
cat build/evidence/toolchain.txt
python3 scripts/test-build-scripts.py 2>&1 | tee build/evidence/signing-policy-tests.log
bash scripts/bootstrap-macos.sh 2>&1 | tee build/evidence/project-generation.log
swift test 2>&1 | tee build/evidence/core-tests.log
swift run ProbeFixtureGenerator build/ControlledFixtures 2>&1 | tee build/evidence/fixture-generation.log
ditto -c -k --keepParent build/ControlledFixtures build/MetadataPhotosProbe-ControlledFixtures.zip
task_destination="$(python3 scripts/select-simulator.py 2>build/evidence/simulator.txt)"
cat build/evidence/simulator.txt
xcodebuild -project MetadataPhotosProbe.xcodeproj -scheme MetadataPhotosProbe \
  -destination "$task_destination" -derivedDataPath build/DerivedData \
  -resultBundlePath build/SimulatorTests.xcresult test \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/evidence/simulator-tests.log
xcodebuild -project MetadataPhotosProbe.xcodeproj -scheme MetadataPhotosProbe \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/MetadataPhotosProbe-unsigned.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/evidence/unsigned-archive.log
ditto -c -k --keepParent build/MetadataPhotosProbe-unsigned.xcarchive build/MetadataPhotosProbe-unsigned-NOT-INSTALLABLE.zip
task_unsigned_payload="$(mktemp -d "${TMPDIR:-/tmp}/metadata-probe-payload.XXXXXX")"
trap 'rm -rf -- "$task_unsigned_payload"' EXIT
mkdir -p "$task_unsigned_payload/Payload"
ditto build/MetadataPhotosProbe-unsigned.xcarchive/Products/Applications/MetadataPhotosProbe.app "$task_unsigned_payload/Payload/MetadataPhotosProbe.app"
ditto -c -k --keepParent "$task_unsigned_payload/Payload" build/MetadataPhotosProbe-UNSIGNED-NOT-INSTALLABLE.ipa
python3 scripts/build-manifest.py --mode unsigned
