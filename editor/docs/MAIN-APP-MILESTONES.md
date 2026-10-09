# Approved production direction

On October 8, 2026 the user reported owner approval of the manual Files/Safari/iCloud Photos workflow and authorized main-app development, explicitly requiring **Flutter + Swift**. This supersedes the earlier SwiftUI production-interface recommendation. The native probe, original research and its device results remain useful and preserved.

Flutter owns the phone interface, validated form/state models and presentation. Swift owns PhotoKit/Files acquisition, immutable sandbox media, format-qualified metadata writing, independent readback/integrity and file export. The canonical tested engine remains linked as a local Swift package; it is not rewritten in Dart. Pinned Flutter/cloud Xcode tooling is independent of Windows source editing and the eventual owner signing channel.

## Milestone 1: working single-file editor foundation

Historical status: version 0.3/build 4 completed this foundation. The restrictions described below belong to that release, not the expanded editor. Version 0.4/build 5 implements milestones 2–4 for the qualified format/field registry; cloud verification and fresh physical-device acceptance are required before calling that expansion complete. See CONFIRMED-FULL-SCOPE.md and DEVICE-TESTS.md for current acceptance criteria. Automatic date/time randomization can be switched off for manual calendar/time entry; bulk processing freezes each item's plan independently.

- Native Photos-original and Files import for JPEG, HEIC, MP4 and MOV, with explicit original/current and Live Photo restrictions.
- Inspect current camera fields, exposed location, dimensions/orientation/profile and known readable capture metadata.
- Edit qualified make/model and image lens; field validation and format-specific unsupported outcomes are enforced natively as well as in Flutter. Blank lens preserves the existing field. HEIC changed camera strings are ASCII-only in the current writer; videos do not expose an editable lens.
- Perform the canonical native write, exact readback and independent data/structure comparison. Known mismatch blocks export; incomplete results require a frozen-output acknowledgment and disclose their limits.
- Recover bounded atomically stored sessions, cancel real operations safely, retain immutable originals and clean up only app-owned copies.
- Export a copy to Files, then guide the accepted explicit browser upload. Neither exporter completion nor browser opening establishes iCloud upload, Photos indexing or source-label absence.
- Flutter unit/widget/contract tests, native store/bridge tests, existing Swift engine tests, independent review, simulator integration and an actual unsigned Flutter/Swift archive/IPA from GitHub macOS.

The editor installs with a separate bundle identity so the diagnostic probe can remain available. Real iPhone testing qualifies the editor integration even though its native engine already has a positive HEIC probe result. Actual MP4/MOV edits with audio/portrait/HDR remain provisional until physical tests pass.

## Milestone 2: full field coverage and selective removal

Version 0.4 implements native editing in these groups: camera/lens/exposure, capture/digitized/modified dates with time-zone rules, GPS and supported descriptive/software fields. Tests cover tag types, ranges, native readback and non-target retention across the supported format registry. Automatic dates can be disabled for manual date/time entry. Actual Photos display remains a physical-device gate.

PNG has its own eXIf reader/writer and independent non-eXIf chunk/pixel checks; it stays PNG. The expanded MetadataPatch HEIC path scrubs retired EXIF extents and selected superseded TIFF values, and selected removal refuses competing unqualified namespaces. The preserved legacy CameraPatch probe path retains old EXIF payloads and remains a diagnostic camera experiment, not a privacy-removal implementation. Maintain the original research on ExifTool namespaces as a reference, not an assumed iOS runtime dependency. Opaque MakerNotes/auxiliary/HDR caveats remain explicit; selected removal does not claim universal anonymization.

## Milestone 3: presets, profiles and randomization

Version 0.4 includes versioned local presets with import/export, fixed edits and reusable camera/randomization recipes. The researched Brand → Model → Camera catalog, configurable ranges and explicit manual overrides produce a frozen typed plan per item before native writes. Retry reuses that plan; persistence, validation and recipe tests cover these paths. Changed embedded camera claims do not authenticate recording provenance. The catalog is extensible and its supported model count is stated rather than claiming every historical phone.

## Milestone 4: bulk processing and recovery

Version 0.4 includes mixed image/video selection, frozen settings and per-item overrides, bounded serial processing, individual errors, collision-safe IMG_#### names, cancellation and retry. Queue state is stored atomically and reconciled against recovered native outputs. Quality and unsupported results remain per file. Actual low-storage provider behavior and large-batch device memory/time/thermal measurements require physical testing.

## Milestone 5: owner release path

Professional code/dependency/license/security/performance reviews, device matrix, signed installation/update/preset retention and owner-provided Zlarp entitlement/distribution contract. No hardcoded credentials, assumed entitlement API or unapproved integration is introduced in the foundation. GitHub unsigned packaging is not proof of installability; Apple signing inputs and the actual customer IPA channel remain separate checks.

Live Photo conversion and CapCut-style visual video editing stay outside scope. Metadata processing is local; provider imports and the accepted Safari/iCloud save workflow may require network access. The manual browser/sync step is an approved product constraint, not a hidden one-tap native save claim.
