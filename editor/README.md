# Zlarp Metadata Editor — Flutter + Swift

The owner accepted local editing followed by **Files -> manual Safari/iCloud Photos upload -> sync**. The user authorized this main-app architecture on October 8, 2026. This first editor milestone uses Flutter for the interface and the canonical separately tested Swift media engine through a versioned native channel. The original SwiftUI probe remains available in the parent directory as a diagnostic reference.

## Working milestone

Import one JPEG, HEIC, MP4 or MOV from Photos or Files; inspect actual native metadata and known readable capture fields; change qualified make/model/image lens; review source/output readback and integrity; export an immutable copy through the Files picker. Native session recovery, app-owned cleanup, real cancellation and structured errors accompany the workflow. Original/provider media are never edited.

HEIC changed camera strings are ASCII-only. Blank lens preserves the existing lens; video lens editing is unsupported. Photos import retrieves the original and refuses Live Photos, so prior visible Photos edits are not implicitly flattened. Files import identifies its coordinated source copy. Image thumbnails are separate display derivatives and never become processed outputs.

Known integrity mismatches block export. Opaque MakerNotes/HDR/container semantics can remain incomplete, requiring an explicit acknowledgment for that frozen output. Passing these checks does not authenticate camera provenance or certify every file. Video support remains provisional pending actual MP4/MOV edits with sound/portrait/HDR on the primary phone; a successful earlier unchanged upload did not qualify processing.

Files exporter completion confirms only a copy. Browser opening confirms only a website was opened. The app neither automatically uploads nor captures Apple credentials; no public API suppression of the native Photos source label is claimed. Final camera display, iCloud synchronization and attribution remain physical-device observations.

## Architecture and source ownership

- `lib/`: Flutter models, typed method-channel adapter, single-operation controller and editor screens.
- `ios/Runner/`: native channel, UIKit/PhotosUI pickers and bounded Swift session store.
- `../../Sources/ProbeCore`: canonical Swift package via local Xcode package path `../..` from `editor/ios` (the repository root). No copied or Dart-reimplemented media writer.
- `test/`, `ios/RunnerTests/`, parent `Tests/ProbeCoreTests/`: Flutter, native integration and engine tests.
- `docs/BRIDGE-CONTRACT.md`: versioned map/ID boundary. Media never travels through channel messages and Dart cannot supply native paths.
- `docs/MAIN-APP-MILESTONES.md`: complete preserved roadmap, including broader fields, PNG, removal, presets/profiles/randomization, bulk/recovery and owner release integration.

No main-app accounts, live Zlarp entitlement API, automatic Photos saves, broad metadata removal, presets or bulk are advertised in this milestone. In particular, the current HEIC writer retains superseded EXIF bytes and is not a privacy-removal implementation.

## Windows and GitHub IPA builder

Use pinned Flutter **3.47.6 / Dart 3.13.5**, framework revision `5fc346839b5d0eef006ed8404392afb4dfae428d`. Windows can run:

```text
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
```

The new `Flutter and Swift metadata editor` GitHub workflow runs the canonical engine tests, Flutter checks, native simulator tests, a real simulator launch and an arm64 iOS archive on macOS. The existing native probe workflow is preserved. macOS runs `bash scripts/build-editor-macos.sh`; its project synchronization script registers new native files and the canonical package without changing Flutter's generated SPM/UIScene integration. Actual SDK/toolchain, exact source revision, logs, framework architectures and checksums accompany artifacts.

The output `Zlarp-Metadata-Editor-UNSIGNED-NOT-INSTALLABLE.ipa` needs valid signing through the user's authorized existing channel. Flutter `--no-codesign` creates an archive but skips signed IPA export; the workflow packages its real device app explicitly. A packaged app, simulator success and successful signed installation are separate evidence. The editor's distinct bundle identifier is `com.vxtiglitch.zlarpMetadataEditor`; it does not replace the probe.

See `docs/VALIDATION.md` for the actual completed run and limitations, and `docs/DEVICE-TESTS.md` for the physical editor test. User media/GPS, local diagnostic reports and signing secrets never enter source or CI.
