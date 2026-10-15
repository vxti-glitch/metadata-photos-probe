# Zlarp licensed release candidate

## Scope and publication boundary

The owner authorized Zlarp license verification and a rebuilt IPA, followed by a final listing preview. No listing creation, artifact upload, deployment, agreement acceptance, or public distribution is authorized by this work. The proposed product slug is `metadata-editor`; proposed pricing is $25 per month. Confirm the exact listing and purchase terms with the owner before any publication.

The release keeps version **1.0.11** and uses a new build number **20**. The exact source commit, CI run, artifact identity, hashes and observed test counts must come from the completed build. Do not reuse build 19 evidence as build 20 evidence.

## Signing and installation

The existing CI workflow produces `Metadata-Editor-UNSIGNED-NOT-INSTALLABLE.ipa`. It is a release candidate for the owner's authorized sideload signing workflow; it cannot be installed directly as downloaded. Zlarp license verification does not sign the IPA, grant Apple entitlements, or validate a signing channel. No signing keys or account-level Zlarp MCP bearer credentials belong in the source or app.

Changing the signing team, application identifier or Keychain access group may require license reactivation. An authorized signer must preserve the intended application identifier or explicitly qualify any changed identity. Do not claim physical installation until it is observed.

## Artifact qualification

The ignored helpers under `build/audit/zlarp-license-release/` are local release tools. Use them only with the full frozen commit and its exact successful push CI run. They must:

1. Verify the GitHub run and downloadable artifact identify the same commit and successful run.
2. Check the download digest, manifest sizes and SHA-256 hashes.
3. Check IPA version/build, identifier, arm64 iOS device binaries, camera catalog, and signing limitations.
4. Compare every source ZIP blob and path against the frozen Git commit.
5. Check actual successful test counts and simulator evidence from that build.
6. Create a fresh package and local listing preview without overwriting prior releases.
7. Record all packaged file hashes and verify the ZIP against its package folder.

Before publication, independently review licensing source and tests, including native enforcement for processing, automatic Files publication and manual single/batch exports. License gating must not replace or weaken media-integrity checks. A successful JWT fixture test is not a successful live customer activation.

## Physical acceptance evidence still required

Record actual device, iOS version, signed build identity and timestamps for each check. Leave unexecuted checks pending.

- Install through the authorized sideload signer; launch in airplane mode without a cached license and confirm the editor is locked.
- Activate a legitimate test license against the live Zlarp service. Confirm success and then relaunch.
- Confirm invalid, expired, revoked and wrong-product licenses fail with useful consumer messages.
- Confirm six-hour refresh, foreground recheck, signed receipt expiry and offline behavior match the implemented policy.
- Confirm license data survives ordinary app relaunch; explain expected reactivation after reinstall or changed signing identity.
- Confirm locked native processing and export paths cannot be invoked through the bridge.
- Confirm activation/retry and Settings remain readable in light and dark appearance, including large text.
- Process and export representative JPEG, PNG, HEIC, MOV and MP4 inputs; run mixed batch processing.
- Repeat the previously failing Photos/TikTok video attempts and inspect exported video playback, audio synchronization, HDR, GPS and requested metadata independently.
- Confirm existing media-integrity warnings and incomplete-check acknowledgment remain accurate.

Live Zlarp activation, real purchase/license delivery, sideload signing/installation and physical Photos/iCloud/HDR behavior remain **pending until actual evidence is recorded**. No automated build changes those pending results.

## Listing preview requirements

The customer listing preview must show the product name, byline, proposed monthly price and clear features. Describe randomization, manual editing, camera profiles, map location, presets and individual/batch workflows without absolute preservation or Apple Photos attribution claims. Keep build numbers, commit hashes, CI links, hashes, test results and qualification blockers in a separate owner-only release report. They are not public marketing copy.

Explain in plain language that this is an iPhone app requiring iOS 17 or later, a valid Zlarp license, internet access for activation and periodic checks, and signing through the customer's sideloading tool. Do not imply the purchase directly installs an unsigned IPA. Record screenshot provenance and capture version in the owner-only report; do not relabel old screenshots as current. Include the support email `vxti.dev@gmail.com`.

Use a disabled purchase control and a clear **LOCAL PREVIEW — NOT PUBLISHED** label. Obtain the owner's approval of this concrete preview before performing any publication or upload.

## Rollback

Preserve the previous build 19 package and source. Keep licensing state independent of media session manifests so reactivation does not erase originals or processed copies. Do not recommend a public rollback to an unlicensed build as a licensing workaround. Any replacement candidate needs its own exact-source CI evidence and package identity.
