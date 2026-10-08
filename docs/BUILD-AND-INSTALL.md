# Build and install the feasibility probe

This repository contains only the native feasibility probe. An IPA proves packaging, not successful installation, correct Photos camera display, absence of imported-source attribution, or preserved media. Those last outcomes remain physical-device gates. Use only disposable fixtures and selected disposable Photos assets.

## Windows development and GitHub IPA builder

Source edits, Git and GitHub Actions dispatch can run on Windows. Compilation, simulator tests and signing run on GitHub's macOS runner. There is no hosted third-party web upload of your source, signing key or media. The app uses Apple's frameworks and the repository's local `ProbeCore` package; XcodeGen is a pinned build-time project generator.

Keep this prototype in a **private** repository. The workflow starts an unsigned validation build on push/PR. It runs signing policy tests, `swift test`, iOS XCTest integration tests on an available simulator, then archives for a generic physical iOS device. Failures do not skip tests to manufacture a successful IPA.

Open **Actions → iOS feasibility probe → Run workflow** to rerun. Leave **signed_export** off until your team signing inputs exist. From Windows GitHub CLI:

```powershell
gh workflow run ios-probe.yml --repo vxti-glitch/metadata-photos-probe --ref codex/metadata-feasibility
gh run list --repo vxti-glitch/metadata-photos-probe --workflow ios-probe.yml --limit 5
gh run watch RUN_ID --repo vxti-glitch/metadata-photos-probe --exit-status
gh run download RUN_ID --repo vxti-glitch/metadata-photos-probe --dir .\downloaded-build
```

The unsigned artifact contains an actual device `.app` archive, an IPA-shaped container explicitly named `UNSIGNED-NOT-INSTALLABLE.ipa`, exact source ZIP, logs, simulator `.xcresult` and checksums. **The unsigned IPA cannot be installed on an ordinary iPhone.** It is useful for compilation review and later authorized signing; do not treat it as a delivered test build. On failure, an artifact may contain only diagnostics.

Before package tests, the workflow runs `swift run ProbeFixtureGenerator build/ControlledFixtures` and uploads a separate `probe-controlled-fixtures-*` artifact. This contains small synthetic original/edited JPEG, HEIC, MP4 and MOV pairs and measured metadata/integrity results where the engine supports each operation. Generating a synthetic original necessarily encodes newly invented image/video content; this is fixture creation, not recompression of imported customer media. The edited pairs must still pass the engine's preservation checks, or their manifest must report unsupported/failure. A generator error fails the workflow; a format-specific unsupported result remains explicit in the fixture report. A successful macOS fixture operation is useful engine evidence, not proof that the same media operation or Photos UI behavior succeeds on your iPhone. Transfer the fixture ZIP through Files/iCloud Drive and extract on the phone; preserve its manifest alongside the case reports.

The runner label is `macos-15`; its installed Xcode image is a provider-managed input, not a pinned SDK. `build/evidence/toolchain.txt` records the actual versions and available SDKs. Set repository variable `PROBE_DEVELOPER_DIR` to an installed Xcode path if a specific version is required. The workflow fails for an unavailable configured path. A compatible selected SDK and simulator must actually pass compilation; no iOS 27.2 SDK availability is assumed. An iOS 17 minimum lets public baseline APIs be compiled by supported Xcode versions; APIs requiring newer systems must be availability-gated.

The simulator chosen may differ from iPhone 15 Pro Max. Its identity is recorded. It checks code/framework behavior; it cannot establish your iOS 27.2 Photos behavior. Record the iPhone's actual **Settings → General → About → iOS Version** and build before testing.

## Signing with the existing Apple Developer team

Use a paid team and its permitted certificate/profile channel. The user has selected the existing GitHub and Apple team, but names, signing material, registered device eligibility and export channel still need to be supplied/configured. Never paste private keys, certificate passwords, Apple account passwords, or provisioning profiles into chat or source code.

Recommended prototype path: **ad hoc** export to the registered iPhone 15 Pro Max, using the team's Apple Distribution certificate and an explicit ad hoc provisioning profile for this app. Alternatively use a development certificate/profile (`debugging`) or an App Store profile (`app-store-connect`) for a manually uploaded TestFlight build. TestFlight export alone is not TestFlight delivery; App Store Connect onboarding, upload/processing and tester access remain separate steps. The workflow does not publish or upload to App Store Connect.

Create a GitHub environment named `ios-signing`. Configure branch restrictions and reviewers appropriate to team ownership before granting signing secrets. Only dispatch reviewed trusted code with signing enabled. An unsigned PR build has no signing secret access. For signed exports, the workflow requires a private repository.

Set environment/repository **variables**:

| Variable | Value |
|---|---|
| `APPLE_TEAM_ID` | The team's 10-character identifier. |
| `BUNDLE_IDENTIFIER` | An explicit app ID owned by that team, e.g. `com.vxtiglitch.MetadataPhotosProbe` if available. |
| `PROBE_DEVELOPER_DIR` | Optional installed Xcode path, matching the unsigned verification job. |

Set environment **secrets**:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64 of the team's authorized signing `.p12`, including its private key. |
| `P12_PASSWORD` | Nonempty export password for that `.p12`. |
| `BUILD_PROVISION_PROFILE_BASE64` | Base64 of the explicit profile matching app ID, team, export channel and registered device when required. |

A team identifier alone cannot sign an IPA. A cloud build service cannot create missing team authority or a private key. The certificate/profile may be exported by the account owner from a Mac/team signing setup, or obtained through the team's existing approved CI process. Do not commit these files. Base64 is encoding, not encryption.

From Windows, enter the Base64 content directly into a secret without printing it:

```powershell
$certificateValue = [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\private\authorized-certificate.p12'))
$certificateValue | gh secret set BUILD_CERTIFICATE_BASE64 --env ios-signing --repo vxti-glitch/metadata-photos-probe
$profileValue = [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\private\probe.mobileprovision'))
$profileValue | gh secret set BUILD_PROVISION_PROFILE_BASE64 --env ios-signing --repo vxti-glitch/metadata-photos-probe
gh secret set P12_PASSWORD --env ios-signing --repo vxti-glitch/metadata-photos-probe
Remove-Variable certificateValue,profileValue
```

Then dispatch the reviewed branch:

```powershell
gh workflow run ios-probe.yml --repo vxti-glitch/metadata-photos-probe --ref codex/metadata-feasibility -f signed_export=true -f export_method=release-testing
```

Signing runs only after verification succeeds. The job validates the team, explicit bundle ID, entitlement identity, expiry and profile channel; imports credentials into an ephemeral runner keychain; archives/exports with manual signing; verifies the exported signature and profile; then removes keychain/profile/temp files on completion or failure. It does not use `-allowProvisioningUpdates` or your Apple password. The signed artifact includes device eligibility in its embedded profile; treat it as private.

Check `signing-summary.json`, `codesign-verification.txt` and `signed-manifest.json` before installing. Signature verification is necessary but does not prove the target device is registered: the app's embedded profile must include your exact UDID, which is intentionally omitted from public logs. Check registration in the team's developer portal. The archive/IPA has a new CI build number on each signed run. The profile's actual expiration is recorded; certificate revocation, expiry or absent registered device can still prevent installation. A signed App Store Connect IPA is for upload, not direct ad hoc installation.

## Install on the primary iPhone

1. Download the verified signed `probe-signed-release-testing-*` artifact and extract its IPA. Confirm its SHA-256 against the signed manifest using `Get-FileHash -Algorithm SHA256` on Windows.
2. For ad hoc/development, use the team's already authorized IPA installation channel (MDM/registered-device deployment or its existing signed OTA installer). Keep the signed identity/profile intact. If that channel requires a one-time PC install, follow its documented instructions; an arbitrary downloadable IPA URL is not an iOS installer. There is no automatic device installer in this repository.
3. If the team lacks an established channel, its Mac administrator can deploy the eligible IPA with Apple Configurator to the registered connected iPhone. For Windows-only users without that channel, choose TestFlight delivery after account-owner upload rather than claiming unsigned artifacts can be installed.
4. For TestFlight, choose `app-store-connect`, upload using the team's approved Mac/App Store Connect process, wait for processing and any required review, invite the tester, and install with Apple's TestFlight app. Each TestFlight build expires; replacement builds are required. This workflow does not configure that account or send invitations.
5. Development-signed installs may require **Settings → Privacy & Security → Developer Mode**, restart and confirmation. Follow the system prompt. Do not disable security controls or use enterprise certificates meant for another organization.
6. Launch **Metadata Probe**. Grant only the required Photos permission when requested. For diagnostic readback/existing edits, make the selected disposable asset accessible under read-write/limited access. Add-only saving cannot verify saved resources or edit existing assets.

If installation fails, preserve the exact error plus build number, channel and profile expiration. Check bundle/team identity, registered device, certificate validity, profile expiry and the device OS. Do not re-sign through an unrelated service as a silent workaround.

## Begin physical testing and retain evidence

Follow [DEVICE-TEST-PROTOCOL.md](DEVICE-TEST-PROTOCOL.md) for the controlled JPEG/HEIC/MP4/MOV matrix and success criteria. Record baseline Photos Info screenshots, then new-resource creation, alternate file-backed creation and supported existing edits. Keep Camera-origin/iCloud-origin controls separate from app-created controls. Test on-device changes only after the save-route control establishes a useful candidate.

Capture the actual camera/lens information and the full source-attribution text, including screenshot-evidenced absence; a `PHAsset.sourceType` value cannot decide that requirement. Recheck after Photos relaunch and iCloud sync settles. Review the app's embedded metadata and integrity reports and export evidence through Files. Unsigned/simulator/source results never replace this hardware evidence. Do not proceed to the full application until the user returns results and explicitly authorizes further work.

## Build locally on an authorized Mac

The same recipe works on a Mac with compatible Xcode and an available iPhone simulator:

```bash
bash scripts/build-macos.sh
# Optional signed export after variables/secrets are securely available in this shell:
bash scripts/sign-macos.sh
```

It downloads the pinned XcodeGen build tool, verifies its published SHA-256, and generates `MetadataPhotosProbe.xcodeproj`. Source and PhotoKit behavior are not mutated by project generation. No dependency installation is needed on Windows. Generated projects and build artifacts should stay out of Git.

## References and qualification boundaries

- [GitHub's Apple signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) describes temporary CI keychains and secret-backed certificate/profile input. This workflow adds explicit identity/channel verification and cleanup.
- [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0) is pinned to its release ZIP and SHA-256; it is a build tool, not an iOS runtime dependency.
- [GitHub runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) changes over time; each run records its actual toolchain.
- [Apple ad hoc profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile) require registered eligible devices.
- [Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) explains its time-limited beta builds.

Only the build logs from an actual successful macOS run establish compilation/test/archive success. A packaged unsigned IPA establishes a build artifact; a verified signed export establishes an eligible installation candidate. Only physical-device results establish installation and Photos feasibility.
