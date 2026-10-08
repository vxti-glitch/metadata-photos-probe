# Metadata Editor — Flutter/Swift editor and preserved feasibility probe

The user has authorized main-app development with **Flutter + Swift**, and the owner accepted explicit Files/Safari/iCloud Photos export. The first working editor lives in [editor/](editor/README.md), with its [full preserved milestone plan](editor/docs/MAIN-APP-MILESTONES.md) and [actual validation record](editor/docs/VALIDATION.md). The canonical Swift engine is shared; the diagnostic app below remains available independently.

## Photos Metadata Feasibility Probe

Single-file SwiftUI/iOS diagnostic app for an iPhone 15 Pro Max running reported iOS 27.2. It tests embedded camera metadata, source/output integrity and public PhotoKit save routes. **It does not suppress attribution or automatically inspect Apple Photos' interface.**

The revised development specification is preserved in [docs/SPECIFICATION.md](docs/SPECIFICATION.md). This repository covers only its first feasibility experiment, not the full editor.

## What is included

- JPEG, HEIC, MP4 and MOV inspection and controlled save experiments. JPEG changes use ImageIO with compressed-data checks; HEIC/video changes use bounded metadata-only container writers and must pass native framework readback. Format support is measured rather than assumed; see [actual results](docs/VALIDATION-STATUS.md). Image lens changes are optional; video lens editing is refused.
- Single-selection Photos picker and coordinated Files staging. Deliberate original/current PhotoKit resource acquisition.
- New asset creation through file resources and file-URL factories.
- Supported existing-asset content editing with baseline identity verification, exact rendered type and versioned diagnostic adjustment data. Previously adjusted, orientation-dependent or incompatible assets are refused.
- File-backed hashing, compressed-image/sample comparisons, saved-resource readback and camera-value checks. Unknown/unqualified structure remains incomplete.
- Manual camera/attribution observations at immediate, relaunched and synchronized phases, with local JSON export.
- Native macOS tests, generated synthetic test fixtures, GitHub Actions IPA/archive builder and optional secure signed export.

There is no bulk processing, randomization/presets, video timeline editing, commercial interface, Zlarp integration or private Apple API.

## Build and install

Follow [BUILD-AND-INSTALL.md](docs/BUILD-AND-INSTALL.md). The GitHub workflow compiles/tests on macOS, logs the actual Xcode/SDK/simulator used, archives for iOS, and creates an unsigned device IPA. **Unsigned packages are not installable until a valid signing channel signs them.** Signed export is optional and requires the matching team certificate/profile in protected GitHub secrets.

Windows can edit the source and dispatch the workflow. It cannot compile PhotoKit/SwiftUI locally with Xcode. Do not interpret a workflow file or syntax check as a successful native build.

## Device experiment

For the current HEIC compatibility patch follow [PROTOTYPE-0.2.1-HEIC-FIX.md](docs/PROTOTYPE-0.2.1-HEIC-FIX.md). The broader [0.2 protocol](docs/PROTOTYPE-0.2-TESTS.md) covers on-device camera changes, Files export and manual Safari/iCloud upload. [DEVICE-TEST-PROTOCOL.md](docs/DEVICE-TEST-PROTOCOL.md) preserves the original direct PhotoKit experiment. Stage A imports a prepared counterpart or unchanged control; Stage B performs the camera change on the device after acknowledging the baseline result.

The two new-asset routes and existing-content-edit route are independent tests. User-recorded label absence is not automatically a full feasibility verdict. Genuine camera, existing iCloud-upload and previously app-attributed controls must be characterized on hardware.

## Evidence and limitations

[VALIDATION-STATUS.md](docs/VALIDATION-STATUS.md) records which checks actually ran. The physical iPhone, Photos camera display, source attribution, iCloud synchronization, real HDR/HEIC/video behavior and signing/install results remain distinct gates.

The engine intentionally does not claim universal lossless integrity. JPEG scans/coding/ICC, HEIC media inventory and video samples/timing/format/transform checks can catch failures, but opaque metadata, HEIF relationships and video container/HDR semantics may remain unqualified. An incomplete diagnostic save is labeled as such; known mismatches cannot be acknowledged away.

Source/provider files are not edited or deleted. A selected existing Photos asset changes only after explicit consent. Original Photos resources can retain old metadata after a visible edit. Existing adjustment reconstruction/revert automation is outside this first probe.

The probe retains staged copies and reports locally until you clear its data or remove the app. Reports can include filenames, locations, asset identifiers and sandbox paths. Nothing is uploaded automatically. Media is excluded from CI and the source repository; never add private fixtures or signing files.

## Source layout

- `Sources/ProbeCore`: native inspection, metadata operations and independent integrity checks.
- `App/Services`: Photos/Files acquisition, save and resource policies.
- `App`: SwiftUI interface, safety gates and evidence collection.
- `Tests/ProbeCoreTests`, `AppTests`: meaningful engine/policy tests.
- `Sources/ProbeFixtureGenerator`: macOS synthetic fixtures; creation encoding is not editing/recompression.
- `project.yml`: XcodeGen source of truth.
- `.github/workflows`, `scripts`: cloud build, packaging, signing-policy validation and manifests.

No runtime third-party libraries are required. Build-time tooling/action versions are pinned. Stop after this probe and review the user's device evidence before any product work.
# Prototype 0.2 follow-up

The current follow-up adds Files/iCloud evidence, separate embedded/library location diagnostics, optional returned-original inspection and bounded HEIC/video metadata-only writers. See [the focused 0.2 hardware protocol](docs/PROTOTYPE-0.2-TESTS.md). Original PhotoKit test documentation remains available for historical context; final cloud validation and remaining device limits are recorded in [validation status](docs/VALIDATION-STATUS.md).
