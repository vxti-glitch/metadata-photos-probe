# Metadata Editor 0.3.0 / build 4 validation

Recorded October 8, 2026. **The first Flutter + Swift editor milestone passed its cloud checks and unsigned packaging. Physical installation and the new editor's phone integration remain unverified.** The final product name is Metadata Editor, with independent bundle `com.vxtiglitch.metadataeditor` and neutral original icon.

## Exact tested source and build

- Source: `2ab358155118390c553d6036acb3352b603bc8f6`, branch `codex/flutter-editor`.
- Successful [GitHub run 37829681331](https://github.com/vxti-glitch/metadata-photos-probe/actions/runs/37829681331), artifact `editor-unsigned-5-1`.
- Flutter 3.47.6, framework `5fc346839b5d0eef006ed8404392afb4dfae428d`; Dart 3.13.5; recorded engine revision `692136cb6582dbfc5af3fb33c2515a069f2f66d0`.
- Cloud macOS 15.7.9, arm64; Xcode 26.2 build 17C52; iOS device/simulator SDK 26.2.
- Hosted native tests and actual launch: iPhone SE (3rd generation) simulator, iOS 26.2 build 23C54. This is a simulator, not the user's iPhone 15 Pro Max/iOS 27.2.
- Deployment target iOS 17.0. Actual app display Metadata Editor / bundle name metadata_editor / version 0.3.0 / build 4 were checked in the archive.

## Completed checks

**126 automated tests passed:** 50 canonical Swift engine tests, 30 Flutter model/controller/channel/widget tests, 18 hosted native session/bridge tests, 17 packaging tests and 11 signing-policy tests. Flutter formatting and analysis passed with no issues. Windows also passed the Flutter tests/analysis and portable packaging checks; Windows did not compile iOS code.

Coverage includes native JPEG import → process → readback/integrity → frozen export → recovery; protected immutable providers; stale/canceled operation handling; tampered output; malformed/oversized journals; traversal/symlink exclusion; bounded Photos streaming; interrupted-staging cleanup; recovered-output requalification; incomplete/mismatch export gates; cache bounds and directory-URL hint regressions. Flutter tests exercise widgets, the typed bridge adapter and state transitions, including readback mismatch, history reconciliation, acknowledgment and cancellation. The native suite does not exercise a real user's Photos library or interactive cloud provider.

The cloud installed and launched the actual Flutter Runner in a simulator, checked the running process and captured `evidence/simulator-editor.png`. The screenshot shows Metadata Editor's neutral header, Photos/Files import controls, four format labels and the manual Files/Safari/iCloud workflow without a startup/channel error. This proves rendering/startup, not physical Photos permission/import/upload behavior.

The release archive contains the native app executable, Flutter.framework and the release Dart App.framework. All actual bounded Mach-O slices are arm64 for the iOS **device** platform; simulator binaries cannot pass packaging. Validated display/bundle names prevent a stale branded archive from being delivered. No provisioning profile or identity signing is included; the unsigned IPA needs the user's authorized signing method. Compiling, packaging, signing and successful installation are distinct checks.

## Frozen artifacts

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Metadata-Editor-UNSIGNED-NOT-INSTALLABLE.ipa | 7130753 | `17ce3de024077a0637386b609522609b15ee0da72a9099fe9ad88294bac03630` |
| Metadata-Editor-source.zip | 305391 | `31b7d37b27cae7eb5dba63c5644dcda9f04d8462f71c3b0236a06b0d91180f28` |
| Metadata-Editor-xcarchive.zip | 47177946 | `3979875f102fb1d37742ffbef7f49129c511442f76d2076fa81cc0b3f8ecb9a9` |

`unsigned-manifest.json` records exact source, workflow, SDK, framework hashes and artifact hashes. The source ZIP is the frozen tested source commit, created before this post-build validation report. This report and installation instructions accompany the delivery separately; documentation-only follow-ups do not change the tested code/IPA. User reports, actual media/GPS, local diagnostic notes and signing inputs were excluded from source/CI; only controlled synthetic fixtures were used.

Earlier failures were resolved before delivery: URL identity compared directory hints rather than filesystem identity, causing false storage errors; strict path-component and separate symlink checks now pass full lifecycle regressions. The initial packager assumed thin Mach-O frameworks; bounded fat-slice validation now checks every actual device slice while rejecting simulator/mixed/malformed inputs. A successful pre-rebrand run also exists, but the delivered package comes from the final neutral-name run above.

## Remaining acceptance gates

The owner-approved save route is manual Files → Safari/iCloud Photos upload → synchronization. Native source-attribution suppression is not established. Previous positive JPEG/HEIC observations belong to the separate probe and those tested cases; this editor still needs signed installation and physical Photos/Files import, edit, export, recovery and final display checks. Start with an ordinary still HEIC/JPEG with Live Photo off. Device instructions describe the new integration check; earlier observations remain valid for their tested cases.

Actual edited MP4/MOV with sound/portrait/HDR remain provisional until phone tests qualify metadata, compressed media, playback, audio, orientation/duration and Photos display. Post-upload exact original bytes, large-file memory/time/thermal behavior, all HEIC structures and opaque MakerNotes/HDR/video side-data remain separate gates. A disclosed incomplete result stays incomplete after acknowledgment. Current HEIC camera edits retain obsolete EXIF bytes and are not a privacy-removal implementation.

Broader fields/PNG/removal, presets/profiles/randomization, bulk processing and owner release integration remain documented future milestones. This delivery completes the first main-editor foundation, not the full commercial feature set.
