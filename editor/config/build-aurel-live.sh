#!/bin/bash
# Staged macOS variant. No private signing credentials belong in this wrapper.
set -euo pipefail
[[ "${1:-}" == --live && "$#" == 1 ]] || { printf '%s\n' 'Use --live explicitly for the staged Aurel live variant.' >&2; exit 1; }
[[ "${AUREL_LIVE_LEGAL_REVIEWED_VERSION:-}" == aurel-live-2026-10-26 ]] || { printf '%s\n' 'Release blocked: review the live legal copy and supply its approved version explicitly.' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'This variant requires macOS and Xcode.' >&2; exit 1; }
task_editor="$(cd "$(dirname "$0")/.." && pwd)"
task_root="$(cd "$task_editor/.." && pwd)"
task_temp="$(mktemp -d -t aurel-live.XXXXXX)"
cp "$task_editor/ios/Runner/Info.plist" "$task_temp/original.plist"
restore_info() { cp "$task_temp/original.plist" "$task_editor/ios/Runner/Info.plist"; rm -rf "$task_temp"; }
trap restore_info EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Requires AUREL_LIVE_PUBLIC_KEY from the separately reviewed production issuer.
# Empty, test and private-key values fail before the build starts.
python3 "$task_editor/config/configure-aurel-live.py" --live "$task_editor/ios/Runner/Info.plist"
export AUREL_BUILD_VARIANT=live
bash "$task_root/scripts/build-editor-macos.sh"
