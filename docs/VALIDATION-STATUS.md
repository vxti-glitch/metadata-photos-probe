# Validation status

## Current prototype 0.2.1 / build 3

Validated October 8, 2026. [GitHub macOS run 37753929324](https://github.com/vxti-glitch/metadata-photos-probe/actions/runs/37753929324) **succeeded** at implementation revision `612fac1b11957804b41adf16eaf1bd352b0c144d`. Subsequent documentation-only commits do not change the compiled app. Independent code review found no blocking issue; final verification separately checks tests, packaging and evidence boundaries.

| Layer | Current evidence |
|---|---|
| Local actual-file diagnosis | The supplied HEIC has one EXIF item describing its primary image and a tone-map representation whose ordered inputs are that primary and an auxiliary gain-map grid. Read-only structural checks matched the narrow supported topology and verified item extents/TIFF bounds. The original's hash remained unchanged. Actual photo, filename, EXIF/GPS payload and local reports were not uploaded to CI. |
| Engine tests | **50 macOS tests passed**, including three new shared-EXIF tests with both TIFF byte orders and either descriptive destination order, raw reference/property/item preservation, 20 invalid graph cases and three unqualified item types. Shared graph fixtures are invented diagnostic payloads; they are not playable Adaptive HDR captures. Existing ImageIO integration tests use independently encoded HEIC. |
| App tests | **27 hosted simulator tests passed**, including the failed-write regression: end progress, clear active staged result and keep historical files, leaving save/export unavailable for the failed operation. |
| Build/signing policy | **11 portable tests passed** locally and in CI. Total **88 tests**, zero failures; simulator tests and generic iOS Release archive succeeded. |
| Toolchain | macOS 15.7.9 arm64, Xcode 16.4 (16F6), Swift 6.1.2 / Swift 5 mode, iOS SDK 18.5; iPhone SE (3rd generation) simulator runtime iOS 26.2. No iOS 27.2 execution is claimed. |
| Integrity limits | Image data, gain-map/tone-map payloads, reference/property bytes and original TIFF body remain preserved by the narrow writer and independent comparisons. Requested ImageIO camera readback remains mandatory. Opaque MakerNotes/HDR semantics remain incomplete; this is not universal lossless or authenticity certification. |
| Package | IPA, archive, source ZIP and fixture ZIP matched manifest byte counts/SHA-256; all ten generated original/processed fixture file hashes matched. Actual IPA is arm64, version 0.2.1/build 3/minimum iOS 17.0, unsigned without a profile or signature. Source ZIP contains no actual media or private device report. |
| Signing / actual photo processing | Signed export skipped. Same authorized signing method as previous builds is required. The new native writer has **not** been run on the supplied physical photo; Windows diagnosis and synthetic/cloud tests are separate evidence. |
| Device/display/provenance | Actual 0.2.1 install, successful same-photo write/readback, Photos camera indexing, HDR appearance, location and synchronized attribution remain phone gates. Direct native attribution suppression remains unverified; existing manual Safari results remain recorded below. |

The compatibility patch supports only the qualified primary/tone-map association. It does not remove safety checks, flatten HDR, decode/re-encode pixels, change Photos provenance or add full-editor features. Repeated writes affect the unique shared EXIF for both described representations, disclosed through integrity limitations; unused original EXIF bytes remain in the file.

Artifacts: `probe-unsigned-13-1`, `probe-controlled-fixtures-13-1` (14-day GitHub retention), retained under `dist/verified-612fac1/`. IPA SHA-256: `6f2657b8f72de690afcc3adf28839b36f5fbc61228772744d17315050da0bbbe`.

See [the focused same-photo retry](PROTOTYPE-0.2.1-HEIC-FIX.md). Sign/install 0.2.1/build 3, choose the same HEIC, repeat Stage B camera writing, then use Files/Safari upload only if exact camera readback succeeds and no known integrity check fails. Inspect actual camera, label, location, orientation and HDR appearance on the target iPhone 15 Pro Max/reported iOS 27.2. Unsupported outcomes remain findings, not permission to convert or bypass checks. Development stops for that result.

The earlier 0.2 and 0.1 snapshots below are preserved as historical evidence.

## Historical prototype 0.2.0 / build 2

Validated October 8, 2026. [Final GitHub macOS run 37751001638](https://github.com/vxti-glitch/metadata-photos-probe/actions/runs/37751001638) **succeeded** for exact implementation revision `363a494ab955c3586ceaefc9c54e2468a7fe167e`. Documentation-only updates after that revision do not change the compiled implementation. Signed export was skipped.

| Layer | Current evidence |
|---|---|
| Portable build/signing policy | 11 tests passed locally and in the final cloud run. |
| Native engine | 47 macOS XCTest cases passed with zero failures, including strict JPEG/HEIC/MP4/MOV camera writes, retained exposed location/orientation, media integrity and adversarial container/TIFF controls. |
| Hosted iOS app | 26 tests passed with zero failures, including separate Files/native observation drafts, frozen returned-original reference, no PhotoKit commit during Files work, persistence failure and stale export callbacks. Simulator tests do not execute physical Photos behavior. |
| Toolchain | macOS 15.7.9 arm64, Xcode 16.4 (16F6), Swift 6.1.2 driver / Swift 5 mode, iOS SDK 18.5. iPhone SE (3rd generation) simulator runtime iOS 26.2. No iOS 27.2 SDK/runtime test is claimed. |
| Controlled fixtures | JPEG, HEIC, MP4 and MOV processed counterparts all passed exact requested make/model readback. Image lens changes are covered separately; video lens writes are refused. Synthetic H.264 videos have no audio and do not qualify real HEVC/HDR/audio/metadata tracks. |
| Integrity | Coded image/media payloads, item graph or video track/sample/timing/format/transform evidence and exposed non-target metadata are independently compared. All five generated processed controls remain **incomplete** for opaque metadata/container/HDR semantics, rather than universally lossless. Known mismatches remain blocked. |
| Packaging | Generic iOS Release archive succeeded. Downloaded IPA, archive, source ZIP and fixture ZIP match manifest byte counts/SHA-256. Fixture file checksums also matched. IPA contains arm64 Mach-O, version 0.2.0/build 2/minimum iOS 17.0, no provisioning profile or code signature. |
| Signing/install | Repository signing secrets/variables remain absent. The package is **unsigned and not ordinarily installable**. Use the authorized signing method used for the first IPA or configure the documented team workflow. No 0.2 installation is claimed. |
| Physical 0.2 follow-up | User reported HEIC recognition followed by `Unsupported media: Exif has ambiguous association` at the on-device write action. Screenshot shows the follow-up interface; exact installed version/build and original file structure have not been independently captured. Successful real-camera HEIC writing remains unverified. |
| Full editor | Not implemented; only the authorized feasibility follow-up. |

The final run passed **84 tests** (47 engine + 26 hosted app + 11 portable). Code review identified TIFF string alignment, shared observation drafts and a stale exporter presentation callback; all were corrected and independently re-reviewed. Final verification separately confirmed scope, tests, packaging and remaining evidence limits.

### Existing physical evidence, distinct from this new build

The user installed a re-signed version 0.1/build 1 on the reported target phone. JPEG camera edits worked, while new assets saved directly by the app displayed **Saved from Metadata Probe**. Existing-asset experiments were blocked by prior-adjustment/orientation guards; they did not establish successful editing or native label-free behavior.

The user's manual Files -> Safari/iCloud.com Photos -> synchronized Photos workflow showed changed JPEG camera information without an unwanted source label. Screenshots showed equal dimensions and rounded size, which do not alone prove unchanged compressed data. The user also reported no unwanted source labels for HEIC, MP4 and MOV uploads. Those latter trials established a save-route observation, not successful on-phone metadata writing by version 0.2. Duplicate warnings remain inconclusive for any trial that does not create an identifiable result.

The JPEG screenshots showed a source location map and a processed image without a map. The new diagnostics expose embedded GPS and library location separately; no location loss cause or automatic repair is claimed. Returned-original inspection is optional and never creates another Photos asset.

The first reported follow-up HEIC attempt reached a deliberately narrow association guard: the unique EXIF item must have a `cdsc` reference whose target list is exactly the primary image alone. The reported error also covers other reference types/targets, so the screenshot does not prove a particular multi-image layout or a corrupt file. Parsing rejected it before creating a processed output or a Photos save. Inspect the actual original HEIC before qualifying additional layouts; do not simply remove the guard or convert to JPEG. The controlled cloud samples did not cover this physical input.

### Delivered 0.2 artifacts

GitHub artifacts: `probe-unsigned-12-1` and `probe-controlled-fixtures-12-1` (14-day retention). Verified local copies: `dist/verified-363a494/`. Build evidence and logs accompany the package. IPA SHA-256: `d2fd353b825b24f1361d38d754246221cf0bb5dbe748223039fcb31622f2a811`.

See [the focused phone test](PROTOTYPE-0.2-TESTS.md) and [build/signing instructions](BUILD-AND-INSTALL.md). Start with an actual disposable HEIC camera patch, export the processed file to Files and upload manually through Safari. Then test camera-patched MOV/MP4 and real-camera video playback/audio/orientation. Do not repeat unchanged-file uploads merely to reproduce the already reported label absence. No undocumented iCloud integration or native attribution suppression was added.

Remaining physical gates include correct camera display, stable attribution after relaunch/sync, GPS-layer interpretation, real HEIC auxiliary/HDR/MakerNotes semantics, HEVC/HDR/audio and opaque video tracks, rotated/large/cloud-only media, permissions/storage/cancellation, eligible existing edits and Revert. This build preserves strict unsupported outcomes; it does not broaden existing-image edits beyond the original upright/unadjusted constraint. Development stops for the user's device results before further application work.

## Historical prototype 0.1 validation

The sections below describe the original delivered implementation and verification date. Their original 'not tested' statements and HEIC/MP4 refusals refer to that earlier validation snapshot; they are superseded by the separately identified current evidence above.

Validated October 7, 2026 (America/New_York). [GitHub macOS run 37722017789](https://github.com/vxti-glitch/metadata-photos-probe/actions/runs/37722017789) **succeeded** for source commit `ae139066fed4c10ae5f3a8c9141dc4d2a905608c`. Its UTC logs are dated October 8. The signed-export job was skipped.

| Layer | Current evidence |
|---|---|
| Windows build/signing scripts | 11 portable signing-policy tests passed locally and in CI; Python, Bash, YAML and plist checks passed. |
| Swift package / app compilation | Passed on macOS 15.7.9 arm64, Xcode 16.4 (16F6), Swift 6.1.2 driver in Swift 5 language mode, iOS SDK 18.5. |
| Native engine tests | 23 macOS XCTest cases passed. Capability tests explicitly record HEIC/MP4 writer refusal rather than successful camera edits. |
| Hosted iOS app tests | 19 policy/evidence XCTest cases passed on iPhone SE (3rd generation) simulator, runtime iOS 26.2. These do not execute physical PhotoKit save/edit experiments. |
| Controlled fixture generation | Generated original JPEG, HEIC, MP4 and MOV plus a separately labeled undated JPEG control; JPEG/MOV processed counterparts available. All fixture-file SHA-256 values checked after downloading. |
| Device IPA packaging | Generic iOS Release archive passed; downloaded IPA contains an arm64 Mach-O app, minimum iOS 17.0. Unsigned, without a provisioning profile, and **not installable** on an ordinary iPhone. |
| Signing | No signing secrets or signing environment were configured in this repository at verification. Signed export and installation were not tested. |
| Physical iPhone | Not tested. |
| Photos camera display | Not tested on hardware. |
| Source attribution | Not tested; not solved. |
| Full HEIC/video preservation | Not certified; conservative incomplete results remain visible. |

Source verification, compilation, simulated integration and physical-device observations are separate results. No full application scope is authorized.

## Measured media outcomes

These are synthetic macOS fixtures, not iPhone camera captures or iPhone processing results.

| Format | Camera operation | Integrity evidence / limitation |
|---|---|---|
| JPEG (dated and undated controls) | Exact make/model readback passed; lens preservation/editing covered by tests. | Compressed scans/coding, non-target application/color blocks, dimensions, orientation and exposed non-target properties passed. Opaque EXIF/XMP qualification remains incomplete. |
| HEIC | ImageIO copy left the original camera values on this host; exact readback rejected the result and removed the failed output. | Original unchanged. No processed HEIC counterpart or successful on-device write is claimed. Use unchanged controls or independently validated prepared counterparts for Stage A. |
| MP4 | AVFoundation same-container passthrough omitted requested camera tags on this host; readback rejected the result and removed the failed output. | Original unchanged. No processed MP4 counterpart or successful on-device write is claimed. Stage A can still test prepared or unchanged MP4. |
| MOV / H.264 | Exact make/model readback passed. | Source/output encoded bytes, timing, format, transforms, track inventory and duration passed. This final fixture has 646 encoded bytes, 19 sample buffers and four matching empty markers. Opaque container/HDR semantics remain incomplete. |

Earlier runs exposed real implementation issues: compiler type errors, conflated JPEG checks, empty MOV sample markers and unsupported camera writes. Those failures are retained in GitHub history. The final JPEG writer merges only requested tags and restores original leading APP13 blocks through bounded streaming; it does not decode or re-encode scans. Tests cover opaque APP13 preservation, malformed/oversized input cleanup and source immutability. No quality gate was bypassed to enable saving.

Whole-file-identical controls can establish exact byte preservation. For changed files, known mismatches block saving; unresolved structure requires explicit diagnostic acknowledgement. Passing guard/capability tests does not qualify all four native writers.

## Delivered build evidence

The downloaded IPA, archive, source ZIP and fixture ZIP all matched the CI manifest's byte counts and SHA-256 values. The IPA SHA-256 is `e382884050439dbf5297df3c91df1a0c6300924c42fa978ec7bdd3d74db72d1f`.

GitHub artifacts are `probe-unsigned-7-1` and `probe-controlled-fixtures-7-1` (14-day retention). Copies are retained locally under `prototype/dist/verified-ae13906/`. The manifest and full logs accompany the unsigned artifact. Documentation-only handoff updates after this source revision do not change the compiled implementation.

Independent code and security reviews identified and corrected stale readback checks, hidden image-lens state in video edits, historical device-context drift, postcommit journal failure labeling and late Photos acquisition after clearing. The hosted tests include an injected successful commit followed by failed persistence and canceled/stale provider callbacks. Final verification independently confirmed the successful run, test counts, actual SDK/runtime and remaining hardware/signing gates.

## Still required on the primary iPhone

Configure the authorized team certificate/profile and variables using [BUILD-AND-INSTALL.md](BUILD-AND-INSTALL.md), export an eligible signed IPA, install it, then run [DEVICE-TEST-PROTOCOL.md](DEVICE-TEST-PROTOCOL.md). Test all four formats for both new-asset routes and eligible existing edits; record unsupported outcomes rather than substituting conversions. Verify actual Settings version/build, baseline origin, saved-resource camera fields, Photos Info camera display and full attribution text at immediate/relaunch/sync phases.

Neither absence of imported-source attribution nor correct Photos camera indexing has been established. Real HEIC auxiliary/HDR data, audio/metadata video tracks, HEVC/HDR, rotated inputs, cloud-only assets, denied/limited access, low storage, interruption and Photos Revert require the documented hardware matrix. Existing edits may be refused for nonupright, previously adjusted or incompatible rendered content. Development stops at this prototype until the user returns device evidence and authorizes further work.
