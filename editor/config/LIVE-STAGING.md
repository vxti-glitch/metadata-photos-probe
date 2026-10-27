# Staged Aurel live variant

This source is not a released app. The template deliberately has no verification pin and must fail closed. Never insert the test pin, a private key, or a placeholder deployment pin.

The live wrapper accepts exactly `--live`, requires `AUREL_LIVE_PUBLIC_KEY` containing the separately reviewed canonical base64 32-byte **public** verification pin, and requires `AUREL_LIVE_LEGAL_REVIEWED_VERSION=aurel-live-2026-10-26` only after review of that version of the in-app notices. The production workflow records technical review of those notices against the implemented activation, account, refund and installation behavior; this is not a legal opinion.

The wrapper selects the exact production endpoint/issuer/environment, restores the original Info.plist on exit, and passes `AUREL_LICENSE_ENV=live` through both Flutter build configurations. It uses the existing full macOS check/build workflow. Default builds retain existing Zlarp/test behavior. Aurel live uses a distinct Keychain namespace and accepts AAL1 keys only.

Before release: independent source review; approved public pin and legal copy; macOS Swift/XCTest and Flutter analysis/tests; signed iPhone installation and monthly/lifetime activation checks; revocation/expiry and wrong-environment denial. Windows portable configuration tests and shell syntax checks do not establish iOS compilation or device acceptance.

## Explicit production CI build

Dispatch `ios-editor.yml` with `build_variant=aurel-live`; push/PR builds and the default dispatch continue to use the standard provider. The workflow supplies only the public verification pin and the reviewed notice version. It checks the actual packaged IPA configuration and writes `evidence/aurel-live-package.json`. Private signing credentials never enter this repository or CI. The unsigned build does not enable checkout or license issuance.

On 2026-10-27 the repository was verified public, with the standard `macos-15` runner. GitHub documents public standard-runner Actions usage as free and assigns artifact quotas to private repositories. Production artifacts are retained for one day; download them promptly. No paid runner, storage limit increase or billing setting is selected.

References: https://docs.github.com/en/billing/concepts/product-billing/github-actions and https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#standard-github-hosted-runners-for-public-repositories
