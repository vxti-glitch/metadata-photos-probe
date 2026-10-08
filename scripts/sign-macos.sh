#!/bin/bash
set -euo pipefail
# Never enable shell tracing here: command arguments include private-key passwords.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
for task_required in BUILD_CERTIFICATE_BASE64 P12_PASSWORD BUILD_PROVISION_PROFILE_BASE64 APPLE_TEAM_ID BUNDLE_IDENTIFIER EXPORT_METHOD; do
  [[ -n "${!task_required:-}" ]] || { printf 'Missing signing input: %s\n' "$task_required" >&2; exit 1; }
done
task_sign_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/metadata-probe-sign.XXXXXX")"
task_keychain="$task_sign_dir/signing.keychain-db"
task_profile_installed=''
task_original_keychains="$(security list-keychains -d user)"
task_cleanup() {
  # Restore without eval: each quoted path is decoded as a line, not executed.
  task_keys=()
  while IFS= read -r task_line; do
    task_line="${task_line#*\"}"; task_line="${task_line%\"*}"
    [[ -n "$task_line" ]] && task_keys+=("$task_line")
  done <<< "$task_original_keychains"
  security list-keychains -d user -s "${task_keys[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$task_keychain" >/dev/null 2>&1 || true
  [[ -z "$task_profile_installed" ]] || rm -f -- "$task_profile_installed"
  rm -rf -- "$task_sign_dir"
}
trap task_cleanup EXIT
printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$task_sign_dir/certificate.p12"
printf '%s' "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$task_sign_dir/profile.mobileprovision"
security cms -D -i "$task_sign_dir/profile.mobileprovision" > "$task_sign_dir/profile.plist"
task_profile_uuid="$(python3 scripts/signing-profile.py "$task_sign_dir/profile.plist" "$task_sign_dir/ExportOptions.plist" build/evidence/signing-summary.json)"
task_key_password="$(openssl rand -hex 32)"
security create-keychain -p "$task_key_password" "$task_keychain"
security set-keychain-settings -lut 3600 "$task_keychain"
security unlock-keychain -p "$task_key_password" "$task_keychain"
security import "$task_sign_dir/certificate.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 -k "$task_keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$task_key_password" "$task_keychain" >/dev/null
security list-keychains -d user -s "$task_keychain"
task_identity="$(security find-identity -v -p codesigning "$task_keychain" | awk 'length($2) == 40 && $2 ~ /^[0-9A-F]+$/ {print $2; exit}')"
[[ "$task_identity" =~ ^[0-9A-F]{40}$ ]] || { printf '%s\n' 'No valid signing identity in certificate/keychain.' >&2; exit 1; }
task_profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$task_profiles_dir"
task_profile_target="$task_profiles_dir/$task_profile_uuid.mobileprovision"
[[ ! -e "$task_profile_target" ]] || { printf '%s\n' 'Refusing to replace an existing installed profile.' >&2; exit 1; }
task_profile_installed="$task_profile_target"
cp "$task_sign_dir/profile.mobileprovision" "$task_profile_installed"
xcodebuild -project MetadataPhotosProbe.xcodeproj -scheme MetadataPhotosProbe \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/MetadataPhotosProbe-signed.xcarchive archive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$task_identity" \
  PROVISIONING_PROFILE_SPECIFIER="$task_profile_uuid" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  OTHER_CODE_SIGN_FLAGS="--keychain $task_keychain" 2>&1 | tee build/evidence/signed-archive.log
xcodebuild -exportArchive -archivePath build/MetadataPhotosProbe-signed.xcarchive \
  -exportPath build/signed -exportOptionsPlist "$task_sign_dir/ExportOptions.plist" \
  2>&1 | tee build/evidence/signed-export.log
task_ipa="$(find build/signed -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$task_ipa" ]] || { printf '%s\n' 'Export did not produce an IPA.' >&2; exit 1; }
unzip -q "$task_ipa" -d "$task_sign_dir/exported"
task_app="$task_sign_dir/exported/Payload/MetadataPhotosProbe.app"
codesign --verify --deep --strict --verbose=2 "$task_app" 2>&1 | tee build/evidence/codesign-verification.txt
codesign -d --entitlements :- "$task_app" > "$task_sign_dir/entitlements.plist" 2>/dev/null
python3 scripts/verify-export.py "$task_app" "$task_sign_dir/entitlements.plist"
python3 scripts/build-manifest.py --mode signed
