# Native probe and Flutter editor scope

The existing native Swift/SwiftUI feasibility probe remains a preserved diagnostic application. The user has now authorized the main application with a Flutter interface and a Swift media engine, and the owner accepted manual Files/Safari/iCloud export. Build the editor additively under `editor/`; retain the canonical Swift engine and its tests. The parent planning research and docs/SPECIFICATION.md remain relevant; the latest user architecture/workflow instruction supersedes their SwiftUI production-interface recommendation.

- Preserve the probe's scope. The first editor milestone is single-file import, inspection, qualified editing, integrity review and Files export/recovery. Presets, randomization, bulk and broader field/removal support remain later planned milestones; accounts and live Zlarp integration require a concrete owner contract.
- Use public Apple APIs. Do not manipulate Photos databases or app-origin attribution.
- Treat embedded metadata, compressed/presentation integrity, and actual Photos UI/attribution as distinct evidence.
- Never infer attribution absence from PHAsset.sourceType or a successful save.
- Keep sources immutable. Existing-asset editing needs explicit consent and disposable test assets.
- No decoding/re-encoding fallback, automatic format conversion or dropped tracks to make a test pass.
- Keep media file-backed and local. No media, resource filenames or GPS in CI/telemetry uploads.
- An incomplete verifier must remain incomplete. Never substitute codec names, previews or mdat equality for integrity evidence.
- Source/build/simulator/device results must be reported separately. Signed IPA installation requires actual signing/channel validation.
- Preserve others' edits. Use focused tests, independent code review and final verification before handoff.
