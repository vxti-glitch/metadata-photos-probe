# Internal release engineering audit — 1.0.11 (17)

Owner scope: internal sideload testing only. Public publication is not authorized. This report supplements the earlier audits with current source findings; it does not replace physical acceptance with automated tests. Exact frozen commit, build identity, final test counts and hashes are recorded in the release manifest and final artifact reports.

## Architecture and audit coverage

The existing Flutter interface remains linked through a bounded method channel to native session management and the canonical Swift ProbeCore package. Dart owns presentation, typed edit intent, presets and batch plans. Swift owns media paths, immutable source copies, metadata-only writers, independent comparisons, processing identifiers and export qualification. Full media does not cross the Flutter channel. Thumbnail decoding is a display operation; it is not the processing output.

Inspection covered the tracked frontend/state/model/bridge modules, canonical TIFF/JPEG/PNG/HEIC/QuickTime writers and inventories, native operation gate/session store, tests, configuration, dependencies and all build/package workflows. This is evidence-based coverage, not a proof that no undiscovered defect exists. The specialist reports document their own scope. The root remains responsible for integration.

Known architectural limits remain: a large metadata form combines UI and draft shaping; format-specific behavior spans the Dart and Swift registries; native Apple readers cannot fully expose every opaque tag/track; file-level metadata and Photos' library indexing/provenance are separate systems. A release-time rewrite would create risk without resolving the physical acceptance gaps, so no speculative refactor was undertaken.

## Confirmed issue register and corrections

| ID | Priority | Reproduction / problem | Correction and regression evidence |
|---|---|---|---|
| R1 | P1 | Full-patch known metadata, GPS and ImageIO property mismatches became acknowledgment-exportable incomplete reports. | Restore failed status for known mismatches. A writer output containing the requested ISO plus an unrequested exposure/GPS change must be mismatch. Genuine unavailable-reader results remain incomplete. |
| R2 | P1 | Selecting one video date exempted every header date from retained-metadata verification. | Exclude only targeted dates and their exact movie-header aliases. A valid date-only rewrite passes; changing a second unrequested track date must fail. |
| R3 | P1 | A latitude/longitude edit exempted unselected altitude from comparison. | Keep normalized unselected components in the comparison. A coordinate-only edit retaining altitude passes; altitude drift must fail. |
| R4 | P1 | Dart silently dropped preset removals in competing metadata files and GPS edits in timed metadata files. | Keep every requested supported operation in the plan; native writers remain the authority for refusal. Two widget regressions fail on the old patch builder and pass on the corrected builder. |
| R5 | P1 | Applying an empty map picker could write the map's default center as explicit GPS. | Require a valid existing location or explicitly selected pin; disable Apply otherwise. Native regression checks cover empty, valid, invalid and newly selected coordinates. |
| R6 | P2 | Native map appearance could disagree with an app-selected Light/Dark mode. | Send the bounded appearance preference and apply it to the native sheet; System continues to follow iOS. |
| R7 | P2 | Malformed export/share completion responses were labeled cancellation. | Require a boolean completed value; malformed responses are errors. Parameterized bridge tests cover missing, null, numeric/string and valid boolean responses. |
| R8 | P2 | Opaque legacy movie location editing failed with a generic message after map-only selection. | Surface a safe actionable explanation that explicit altitude handling is needed; preserve the native refusal. No unknown altitude is invented or removed. |

No confirmed P0 was found in this audit. This statement does not certify arbitrary source media or physical-device behavior. Earlier batch timezone, filename reservation, recovery, cancellation and integrity export gates are retained and exercised by the existing suites.

## Test and native build report

Required gates: Flutter analysis and format checks, full widget/unit tests, canonical Swift tests, native hosted Runner tests, packaging tests, build-policy tests, simulator installation/launch and arm64 device archive. New native tests cannot execute in Windows and must pass in the exact-source macOS build before packaging. The final artifact contains raw logs and independent qualification reports, which are authoritative for counts and outcomes.

Synthetic fixtures cover clean and malformed JPEG/HEIC/PNG/MOV/MP4, missing/existing metadata, selected removal, mixed batch shaping, frozen retry plans, unsupported container structures, cancellation, recovery, symlinks/path traversal, bounded input/state and export tampering. New drift controls include both valid and invalid rewrites; tests do not merely repeat implementation conditions.

ExifTool and ffprobe were not present in the local PATH during this audit. Native target readback uses ImageIO/AVFoundation independently of the bounded container writer/parser, plus structural and compressed-payload comparisons. No external-tool or physical-device result is invented. The synthetic 4K H.264/AAC test records metadata rewrite and verification time; it is a short host fixture, not a long-video, memory or handset benchmark.

## Remaining issues and release decision

Internal candidate: CONDITIONAL GO only for authorized signing followed by controlled hardware acceptance, after the final exact-source build and artifact qualification pass. It is not a directly installable binary. Public release: NO-GO; public distribution is outside the owner-selected scope, and required signing/install/Photos/device acceptance is not established.

Remaining gates: secure signing credentials/channel, a signed installation on an eligible iPhone, all five-format Photos/provider acceptance, the previously reported private Photos MOV failure, background/low-storage/long-media behavior, real HDR/HEIC auxiliary-media acceptance and actual system provenance labels. Neither raw metadata nor a successful save establishes attribution absence.

The older untracked 1.0.10 release-candidate guide contains unvalidated distribution instructions. Preserve it as historical evidence; use the corrected signing/distribution report and this candidate's notes for the current handoff.

## Freeze and rollback

No new features are included. Freeze the final commit after review and required gates. The release package must match that exact Git source, version/build, IPA hash and successful cloud run. Preserve 1.0.9 and 1.0.10 artifacts; do not overwrite them.

If the candidate fails acceptance, stop using its processed copies, preserve the failure code/known check labels locally, and return to the earlier artifact through the authorized signing process. Originals remain the source of truth. Installing an older build can interact with persisted state; use a separately backed-up test set and export required local work before uninstalling. Rebuilding a historical revision does not reproduce its historical binary hash. Files/Safari/iCloud uploads are user-operated and may need manual deletion of disposable test assets; no automatic Photos rollback is promised.

## Deliverable index

This file provides the engineering audit, resolved issue summary, remaining issues, automated/native test report, readiness decision and rollback plan. `media-and-photos.md` provides metadata/preservation evidence and the Photos compatibility matrix. `release-security.md` covers security/privacy, packaging/signing and safe internal distribution. `physical-acceptance.md` gives the exact hardware checklist. `flutter.md` and `native-review.md` contain specialist review evidence. The final artifact's RELEASE-NOTES, manifest, logs, hashes and qualification report complete release notes and known limitations for the actual built revision.
