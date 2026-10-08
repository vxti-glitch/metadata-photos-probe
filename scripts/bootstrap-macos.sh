#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'This step requires macOS.' >&2; exit 1; }
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tools="$task_root/.tools/xcodegen-2.46.0"
mkdir -p "$task_tools"
task_zip="$task_tools/xcodegen.zip"
curl --fail --location --retry 3 --output "$task_zip" \
  'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip'
printf '%s  %s\n' '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' "$task_zip" | shasum -a 256 --check
unzip -oq "$task_zip" -d "$task_tools"
task_generator="$(find "$task_tools" -type f -name xcodegen -perm +111 -print -quit)"
[[ -n "$task_generator" ]] || { printf '%s\n' 'Verified archive did not contain an executable xcodegen.' >&2; exit 1; }
"$task_generator" --version
cd "$task_root"
"$task_generator" generate --spec project.yml
