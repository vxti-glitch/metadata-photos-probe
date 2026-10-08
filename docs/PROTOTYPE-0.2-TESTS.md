# Prototype 0.2: Files/iCloud and metadata-writing tests

This remains a single-file feasibility probe. No bulk editor, presets, randomizer or Zlarp integration is included. Use the same signing/install method used for the first IPA; keep the bundle identity when possible to preserve local evidence. A re-signed build with a different bundle identity will have different app storage and permission state. The unsigned cloud IPA still needs valid signing before ordinary iPhone installation.

## What changed

- A dedicated **Save a copy to Files** action exports the actual staged file through Apple's Files picker. It keeps the local reference and records requested, completed or canceled export independently from PhotoKit.
- File processing and user-reported Safari/iCloud observations are included in evidence JSON even when no native Photos save occurs. Old evidence remains readable.
- Source and processed inspections show exposed embedded GPS. Original/current Photos-resource retrieval also records the separate library location. No coordinates are silently inserted or repaired.
- Optional **Inspect returned iCloud photo** retrieves that asset's original and compares it against a frozen processed-file reference without saving another asset or replacing the active baseline.
- HEIC and MP4/MOV metadata writers use bounded metadata-only container changes. They preserve coded media in place and refuse layouts they cannot safely validate. Independent ImageIO/AVFoundation camera readback and integrity checks remain mandatory. Full opaque/HDR/auxiliary semantic qualification is still incomplete even when inspected media checks pass.

## First hardware test: actual HEIC camera changes

1. Capture a disposable ordinary High Efficiency photo with RAW and Live Photo off. Choose it in the app, then **Retrieve original Photos resource**. This is important for differentiating picker output from original file metadata.
2. Review **Source metadata → Embedded location** and **Source Photos library location**. Capture that screen if they differ. A library map with no embedded coordinates is a separate-layer result, not automatic evidence of a writer losing GPS.
3. Select **Stage B · on-device change** and acknowledge that you completed the baseline upload test for this format. Enter different camera make/model and, optionally, lens values. Use ASCII camera fields for the controlled HEIC test; Unicode TIFF camera strings are not qualified.
4. Tap **Write camera metadata on this device**. Inspect staged make/model/lens, exposed GPS and integrity. If unsupported or a mismatch occurs, export the evidence/error; do not convert the file or remove a gate to proceed.
5. Tap **Save a copy to Files**. Do not run the optional direct PhotoKit save. Upload the exported copy via Safari at iCloud.com/photos, choosing the exact file from Files.
6. After sync, inspect Photos Info: requested camera values, source label, displayed location, format and image appearance. Record your actual observation in **Files/iCloud test evidence**, then export evidence JSON.

This is different from the earlier unchanged-file uploads: it qualifies metadata processing on the iPhone. A duplicate warning is inconclusive if it prevents a distinct upload. Keep source and output; do not delete valuable library items or rename formats to bypass checks.

## Video hardware tests

Repeat Stage B for one disposable MOV and one controlled MP4, checking make/model and leaving lens empty. Use supplied fixtures first; then a real short H.264/HEVC camera recording, with sound, if its container is supported. Verify actual playback, audio, orientation, duration, source label and any camera information the Photos UI exposes. Video Info may expose fewer camera fields than still-photo Info: record the actual display, not an assumed result.

The writer refuses fragments, protected media, external references, unqualified sample/atom layouts and headers exceeding its bounded budget. A refusal is a measured limitation. It does not permit transcoding or dropping an opaque track. HDR/HEVC, transformed portrait recordings, auxiliary metadata tracks and larger real captures still need separate trials; synthetic success does not certify them.

## Optional returned-photo diagnostic

Choose the relevant frozen file test under **Files/iCloud test evidence**, then **Inspect returned iCloud photo (optional)** and select the synced processed result. Grant read/write access to that selected asset if asked. This reads the original, records its separate Photos-library location and compares file content; it performs no PhotoKit save.

Interpret location results:

| Source/processed/returned evidence | Meaning |
|---|---|
| Source library location present, source embedded GPS not found | The map was not established as embedded in the processed input. No automatic library-to-file repair occurs. |
| Source GPS present, staged GPS differs | Processing failed preservation. Export remains blocked for a known mismatch. |
| Staged GPS present, returned GPS absent/different | The export/upload/return boundary needs investigation. |
| Returned embedded GPS present, returned library location absent | File metadata and Photos indexing disagree. The native writer did not necessarily lose coordinates. |
| Any layer not checked/incomplete | Preserve the uncertainty; do not treat it as no GPS or a passing result. |

Your earlier screenshot's missing map remains unexplained until these layers are measured. Choosing a different Photos result or duplicate can also invalidate the comparison.

## Evidence boundaries and stopping point

The existing user tests show a positive JPEG visual attribution result and user-reported absence of source labels for HEIC, MP4 and MOV through manual web uploads. Those results do not certify this new build, all-format on-device metadata writing or unchanged compressed media. Actual iOS version/build, signing identity and media structures must be recorded separately.

Cloud tests establish compilation and controlled file behavior. Physical iPhone tests establish Photos display, attribution, real-camera processing and upload/sync behavior. Stop after this prototype's test results; full application development remains separately authorized work.
