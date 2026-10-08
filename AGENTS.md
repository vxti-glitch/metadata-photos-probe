# Feasibility probe scope

This repository implements only the native Swift/SwiftUI Photos metadata feasibility probe. The parent `Zlarp-Metadata-Editor-iPhone-First-Revision.md` is the specification; a portable copy is in docs/SPECIFICATION.md.

- Do not add bulk processing, randomization/presets, commercial UI, accounts or Zlarp integration.
- Use public Apple APIs. Do not manipulate Photos databases or app-origin attribution.
- Treat embedded metadata, compressed/presentation integrity, and actual Photos UI/attribution as distinct evidence.
- Never infer attribution absence from PHAsset.sourceType or a successful save.
- Keep sources immutable. Existing-asset editing needs explicit consent and disposable test assets.
- No decoding/re-encoding fallback, automatic format conversion or dropped tracks to make a test pass.
- Keep media file-backed and local. No media, resource filenames or GPS in CI/telemetry uploads.
- An incomplete verifier must remain incomplete. Never substitute codec names, previews or mdat equality for integrity evidence.
- Source/build/simulator/device results must be reported separately. Signed IPA installation requires actual signing/channel validation.
- Preserve others' edits. Use focused tests, independent code review and final verification before handoff.
