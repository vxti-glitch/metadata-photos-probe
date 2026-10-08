#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_sdk="$task_root/.tools/flutter-3.47.6"
task_commit='5fc346839b5d0eef006ed8404392afb4dfae428d'
mkdir -p "$task_root/.tools"
if [[ ! -d "$task_sdk/.git" ]]; then
  [[ ! -e "$task_sdk" ]] || { printf '%s\n' 'Flutter SDK destination exists without a Git checkout.' >&2; exit 1; }
  git clone --depth 1 --branch 3.47.6 https://github.com/flutter/flutter.git "$task_sdk"
fi
[[ "$(git -C "$task_sdk" rev-parse HEAD)" == "$task_commit" ]] || { printf '%s\n' 'Pinned Flutter framework revision mismatch.' >&2; exit 1; }
[[ -z "$(git -C "$task_sdk" status --porcelain --untracked-files=no)" ]] || { printf '%s\n' 'Pinned Flutter framework has tracked changes.' >&2; exit 1; }
"$task_sdk/bin/flutter" --suppress-analytics --version
"$task_sdk/bin/flutter" --suppress-analytics precache --ios
printf '%s\n' "$task_sdk/bin"
