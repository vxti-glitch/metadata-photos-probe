# Approved production direction

On October 8, 2026 the user reported owner approval of the manual Files/Safari/iCloud Photos workflow and authorized main-app development, explicitly requiring **Flutter + Swift**. This supersedes the earlier SwiftUI production-interface recommendation. The native probe, original research and its device results remain useful and preserved.

Flutter owns the phone interface, validated form/state models and presentation. Swift owns PhotoKit/Files acquisition, immutable sandbox media, format-qualified metadata writing, independent readback/integrity and file export. The canonical tested engine remains linked as a local Swift package; it is not rewritten in Dart. Pinned Flutter/cloud Xcode tooling is independent of Windows source editing and the eventual owner signing channel.

## Milestone 1: working single-file editor foundation

- Native Photos-original and Files import for JPEG, HEIC, MP4 and MOV, with explicit original/current and Live Photo restrictions.
- Inspect current camera fields, exposed location, dimensions/orientation/profile and known readable capture metadata.
- Edit qualified make/model and image lens; field validation and format-specific unsupported outcomes are enforced natively as well as in Flutter. Blank lens preserves the existing field. HEIC changed camera strings are ASCII-only in the current writer; videos do not expose an editable lens.
- Perform the canonical native write, exact readback and independent data/structure comparison. Known mismatch blocks export; incomplete results require a frozen-output acknowledgment and disclose their limits.
- Recover bounded atomically stored sessions, cancel real operations safely, retain immutable originals and clean up only app-owned copies.
- Export a copy to Files, then guide the accepted explicit browser upload. Neither exporter completion nor browser opening establishes iCloud upload, Photos indexing or source-label absence.
- Flutter unit/widget/contract tests, native store/bridge tests, existing Swift engine tests, independent review, simulator integration and an actual unsigned Flutter/Swift archive/IPA from GitHub macOS.

The editor installs with a separate bundle identity so the diagnostic probe can remain available. Real iPhone testing qualifies the editor integration even though its native engine already has a positive HEIC probe result. Actual MP4/MOV edits with audio/portrait/HDR remain provisional until physical tests pass.

## Milestone 2: full field coverage and selective removal

Expand native editing in tested groups: camera/lens/exposure, capture/digitized/modified dates with time-zone rules, GPS and supported descriptive/software fields. Verify tag types, ranges, native readback, non-target retention and every required format separately; do not advertise a control before its writer qualifies.

PNG remains in the original product scope and needs its own reader/writer/pixel/structure gate. Selective removal requires new native deletion semantics and residual-data checks: the current HEIC camera writer deliberately retains obsolete EXIF payloads, so it is not a privacy-removal implementation. Maintain the original research on ExifTool namespaces as an oracle, not an assumed iOS runtime dependency. Keep opaque MakerNotes/auxiliary/HDR caveats explicit.

## Milestone 3: presets, profiles and randomization

Versioned local presets and import/export; consistent camera/lens profiles; configurable ranges and field selection; deterministic seeded plans and retries; validation and migration tests. Generate a frozen typed patch before invoking native writes. Do not claim the camera provenance is authentic merely because embedded fields changed.

## Milestone 4: bulk processing and recovery

Mixed image/video selection, frozen settings and per-item overrides, bounded worker/resource budgets, individual errors, collision-safe naming, cancellation, low-storage handling and retry. Persist queue state atomically, reconcile uncertain external operations and measure actual device memory/time/thermal behavior. Keep quality and unsupported results per file.

## Milestone 5: owner release path

Professional code/dependency/license/security/performance reviews, device matrix, signed installation/update/preset retention and owner-provided Zlarp entitlement/distribution contract. No hardcoded credentials, assumed entitlement API or unapproved integration is introduced in the foundation. GitHub unsigned packaging is not proof of installability; Apple signing inputs and the actual customer IPA channel remain separate checks.

Live Photo conversion and CapCut-style visual video editing stay outside scope. Metadata processing is local; provider imports and the accepted Safari/iCloud save workflow may require network access. The manual browser/sync step is an approved product constraint, not a hidden one-tap native save claim.
