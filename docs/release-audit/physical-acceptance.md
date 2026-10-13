# Internal iPhone acceptance checklist

Use disposable, non-sensitive originals and a signed candidate from an authorized signing process. Do not post media, filenames, GPS, certificates or passwords to CI or public issues. Record candidate version/build, IPA hash, signing channel and iPhone/iOS version locally. An unsigned IPA is not an installation result.

## Installation and interface

1. Install the correctly signed candidate; record successful launch. If an existing test installation is replaced, preserve necessary local work first.
2. Open Home, Settings, Appearance, Local projects, Saved presets, Error reference guide, export/media details, diagnostics and app information; navigate back through each.
3. Select System, Light and Dark. Check native map appearance as well as Flutter screens. Enable a large accessibility text size, rotate where supported, and check safe areas, controls and scrolling.
4. Import a JPEG, HEIC, PNG screenshot, MOV and MP4 independently from Files and Photos. Test limited/denied Photos permission, a provider download and cancellation. Unsupported media must have a clear error and leave originals intact.

## Editing and processing

5. Confirm auto-matched phone/brand, choose another camera, and review the prepared fields. Change supported ISO/shutter/aperture, dates/timezone, and a saved preset. Verify manual Keep/Set/Remove intent rather than trusting only displayed form values.
6. Open Location without existing GPS. Apply must be unavailable until a pin is chosen. Cancel must retain the prior plan. Pick a point and verify coordinates; check altitude explicitly for opaque movie-location errors.
7. Process each format. Inspect every optional Details report. A failure must provide no new exportable output; a limited result must state its limits and require acknowledgment.
8. Export to Files. Compare output format, selected metadata and original source hash locally with an independent reader where available. Verify the original did not change and no image/video conversion happened.
9. Select several files including video first, then images/screenshots. Confirm every supported file receives the shared requested patch, names are distinct, and each failure is visible. Test a mixed batch with one unsupported/restricted input, retry, then reopening local history.
10. Compare image dimensions, orientation, transparency/color and HEIC auxiliary behavior. Play videos with sound from start/middle/end; inspect duration, seek, frame cadence, audio synchronization and HDR on a suitable display. Include long 4K and real HDR samples locally.

## Reliability and Photos

11. Background during import/process, return, cancel where available, relaunch and inspect recovered state. Repeat edits/exports and watch memory/storage/heat; test with low free storage using disposable files. Never delete production originals to create a test condition.
12. Use the owner-approved Files -> Safari/iCloud Photos workflow for each accepted format. Record uploader refusals accurately. Do not rename/convert to make a test pass.
13. After sync, inspect actual Photos Info for make/model, lens/exposure where shown, capture time, timezone handling, GPS map and orientation. Record missing UI fields separately from missing file metadata.
14. Inspect provenance/app-origin labels; successful upload alone does not establish absence. Direct PhotoKit attribution is a separate observation and is not the approved no-label claim.
15. Reproduce the earlier Photos video failure locally; record only the error code and safe failed-check labels for diagnosis. Keep the original private sample local.
16. Verify original assets, sources and any required local work are intact. Record each test PASS/FAIL/PENDING with evidence and candidate identity. Do not declare device acceptance from simulator screenshots.

Stop acceptance on corruption, changed originals, hidden batch failure, wrong requested values or an exported mismatch. Quarantine test outputs and return to the preserved known build using the authorized signing process. Public launch remains unapproved; this checklist covers internal testing only.
