# Aurel Archive test licensing build

The normal build remains the existing Zlarp edition. The public plist in this directory configures only the Aurel **sandbox** issuer, endpoint and Ed25519 verification pin. It contains no private key. Live licensing is deliberately unsupported by this configuration.

On macOS with the repository's required Flutter/Xcode dependencies, from `editor/` run:

```sh
bash config/build-aurel-test.sh
```

The script backs up `ios/Runner/Info.plist`, merges all three public Aurel test values for the build, and restores the original plist on exit. Do not run simultaneous builds from the same checkout. Review the final app's embedded Info.plist to confirm all three values before testing. Do not publish this test build to paying customers or replace the existing Zlarp release with it. The produced app is unsigned and needs authorized signing before installation; this script neither signs nor packages an IPA.

A partial or invalid configuration blocks activation without contacting Zlarp. Aurel test tokens require `iss=aurel-archive-test`, `env=test`, `aud=metadata-editor`, active entitlement, matching device and fresh nonce, a valid signature and unexpired expiry. Aurel keys/cache use a separate Keychain service from Zlarp.

Before release: run native XCTest/Swift tests and the cloud iOS build, update the provider-specific legal/support text, and test an actual signed iPhone build against purchase, owner isolation, cancellation/expiry, lifetime and revoked access. Source/Flutter checks do not establish that device acceptance.
