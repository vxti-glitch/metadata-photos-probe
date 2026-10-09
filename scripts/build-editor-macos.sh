#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Flutter iOS compilation requires macOS and Xcode.' >&2; exit 1; }
task_build="$task_root/build/editor"
mkdir -p "$task_build/evidence"
# Runner inventory lists supported choices. Record the choice, never silently accept an unknown Xcode.
if [[ -n "${DEVELOPER_DIR:-}" && -d "${DEVELOPER_DIR}" ]]; then
  export DEVELOPER_DIR
elif [[ -d /Applications/Xcode_26.2.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
elif [[ -d /Applications/Xcode-26.2.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer
elif [[ -d /Applications/Xcode_16.4.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
elif [[ -d /Applications/Xcode-16.4.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-16.4.app/Contents/Developer
elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
elif selected_xcode="$(xcode-select -p 2>/dev/null || true)" && [[ -n "$selected_xcode" && -d "$selected_xcode" ]]; then
  export DEVELOPER_DIR="$selected_xcode"
else
  printf '%s\n' 'Neither supported pinned Xcode selection is installed.' >&2
  exit 1
fi
{
  date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
  git rev-parse HEAD
  sw_vers
  uname -m
  printf 'Selected DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
  xcodebuild -version
  xcodebuild -showsdks
  swift --version
  ruby --version
  if ! ruby -rxcodeproj -e '' 2>/dev/null; then
    gem install xcodeproj --no-document --user-install || gem install xcodeproj --no-document || true
  fi
  ruby -rxcodeproj -e 'puts "xcodeproj #{Xcodeproj::VERSION}"'
  xcrun simctl list devices available
} > "$task_build/evidence/toolchain.txt" 2>&1
cat "$task_build/evidence/toolchain.txt"
bash scripts/editor-bootstrap-flutter.sh 2>&1 | tee "$task_build/evidence/flutter-bootstrap.log"
task_flutter="$task_root/.tools/flutter-3.47.6/bin/flutter"
task_dart="$task_root/.tools/flutter-3.47.6/bin/dart"
"$task_flutter" --suppress-analytics --version --machine > "$task_build/evidence/flutter-version.json"
python3 scripts/test-build-scripts.py 2>&1 | tee "$task_build/evidence/signing-policy-tests.log"
python3 scripts/editor-package-tests.py 2>&1 | tee "$task_build/evidence/editor-packaging-tests.log"
swift test 2>&1 | tee "$task_build/evidence/core-tests.log"
cd "$task_root/editor"
"$task_flutter" --suppress-analytics pub get --enforce-lockfile 2>&1 | tee "$task_build/evidence/dependency-resolution.log"
"$task_dart" format lib test 2>&1 | tee "$task_build/evidence/flutter-format.log"
git diff --no-ext-diff > "$task_build/evidence/dart-format.patch" || true
"$task_flutter" --suppress-analytics analyze --fatal-infos 2>&1 | tee "$task_build/evidence/flutter-analysis.log"
"$task_flutter" --suppress-analytics test --reporter expanded 2>&1 | tee "$task_build/evidence/flutter-tests.log"
# Generates the current Flutter framework and local plugin package before Xcode resolves it.
"$task_flutter" --suppress-analytics build ios --simulator --debug --config-only --no-codesign 2>&1 | tee "$task_build/evidence/flutter-ios-configuration.log"
ruby "$task_root/scripts/editor-sync-project.rb" 2>&1 | tee "$task_build/evidence/project-sync.log"
task_destination="$(python3 "$task_root/scripts/select-simulator.py" 2>"$task_build/evidence/simulator.txt")"
cat "$task_build/evidence/simulator.txt"
# Hosted tests share one Flutter app process. Serial execution avoids simulator clones and
# makes session/import failures attributable to one test without masking a failing result.
set +e
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination "$task_destination" -derivedDataPath "$task_build/DerivedData" \
  -resultBundlePath "$task_build/NativeTests.xcresult" -parallel-testing-enabled NO test \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$task_build/evidence/native-tests.log"
task_native_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$task_native_status" > "$task_build/evidence/native-test-exit.txt"
python3 "$task_root/scripts/editor-test-results.py" --result "$task_build/NativeTests.xcresult" \
  --evidence "$task_build/evidence" 2>&1 | tee "$task_build/evidence/native-test-diagnostics.txt" || true
[[ "$task_native_status" == 0 ]] || exit "$task_native_status"
task_simulator_id="${task_destination##*id=}"
task_simulator_app="$task_build/DerivedData/Build/Products/Debug-iphonesimulator/Runner.app"
[[ -d "$task_simulator_app" ]] || { printf '%s\n' 'Simulator test build did not produce the editor app.' >&2; exit 1; }
if ! xcrun simctl list devices booted | grep -Fq "$task_simulator_id"; then
  xcrun simctl boot "$task_simulator_id"
fi
xcrun simctl bootstatus "$task_simulator_id" -b
xcrun simctl install "$task_simulator_id" "$task_simulator_app"
task_launch="$(xcrun simctl launch "$task_simulator_id" com.vxtiglitch.metadataeditor)"
printf '%s\n' "$task_launch" | tee "$task_build/evidence/simulator-launch.txt"
# Allow first-frame rendering; a screenshot documents simulator UI, never Photos provenance.
sleep 5
xcrun simctl spawn "$task_simulator_id" launchctl list | grep -F com.vxtiglitch.metadataeditor > "$task_build/evidence/simulator-running.txt"
xcrun simctl io "$task_simulator_id" screenshot "$task_build/evidence/simulator-editor.png"
"$task_flutter" --suppress-analytics build ipa --release --no-codesign 2>&1 | tee "$task_build/evidence/unsigned-archive.log"
cd "$task_root"
python3 scripts/editor-package.py --archive editor/build/ios/archive/Runner.xcarchive --output build/editor
git archive --format=zip --output="$task_build/Metadata-Editor-source.zip" HEAD
python3 scripts/editor-package.py --manifest-only --output build/editor
