# Video camera metadata layout test candidate

## Distribution boundary

The owner authorized a corrected **test IPA** for direct physical iPhone validation. This candidate is **not authorized for a public Zlarp replacement yet**. Keep the current public build 21 delivery, listing, screenshots, monthly price and licensing unchanged. Preserve all prior source and release packages for rollback.

The candidate is version **1.0.11, build 22**. The frozen source commit, successful push CI run, artifact ID, actual passing check counts and IPA SHA-256 belong in its generated owner report. Do not reuse evidence from build 21 as build 22 evidence.

## Compatibility issue under investigation

The processed-video Photos screenshot showed "No camera information" while showing a lens description. The native reference showed a make/model camera row. Earlier source fixes corrected metadata values and qualified independent reader behavior by movie format; those results did not establish the physical Photos camera display.

The new candidate addresses the layout of movie-level keyed metadata: a direct `moov/meta` box with the unversioned QuickTime layout, and consistent treatment of existing direct or nested keyed metadata. A reader accepting metadata written in another placement is not proof that Photos will present the same camera identity. Native-reader and synthetic fixture results must be taken from the final CI run; the expected improvement in Photos remains unverified until the owner tests this candidate.

The change must preserve encoded video and audio samples, tracks, codec, dimensions, timing and real HDR information. It must not re-encode a file or invent HEVC/Dolby Vision labels to resemble an unrelated native recording. Existing hard media-integrity checks and the approved retained-metadata warning policy remain in force.

User-supplied videos and their private filenames, GPS and metadata remain local. No private samples belong in Git, CI, release packages or listing media. Regressions use synthetic fixtures.

## Build and artifact evidence

Use the existing `ios-editor.yml` workflow and its pinned toolchain. The ignored helpers in `build/audit/video-camera-layout-release/` bind the download to the exact successful push run and frozen commit. They verify GitHub artifact digest, manifest and IPA hashes, version/build, arm64 iOS device architecture, camera catalog bytes and every source ZIP blob. Recorded test counts derive from that run's evidence logs.

Outputs use a fresh `Metadata-Editor-TEST-v1.0.11-video-camera-layout-<commit>` directory and ZIP. Never overwrite the previous build 21 package or the older build 20 packages. The package status is **LOCAL TEST CANDIDATE - NOT PUBLISHED**. Source/build/simulator evidence is separate from installation and physical Photos evidence.

The unsigned IPA requires authorized sideload signing. License activation does not provide signing. A successful automated build cannot establish installation, Photos metadata display, attribution, iCloud import behavior, playback or HDR preservation on an actual device.

## Owner iPhone acceptance procedure

Record the installed app version/build, source SHA from its package, iPhone model and iOS version with each result. Do not upload the owner's private media or GPS to CI.

1. Sign and install this exact build 22 IPA using the established sideload workflow. Confirm launch and existing license access.
2. Process one previously failing video with the detected phone model and intended camera. Export its new copy to Files with a distinct filename; retain the untouched input.
3. Import that exported copy through the same normal Photos workflow. Open the newly imported asset, not the original or a cached earlier export. Inspect the camera make/model row and lens description. Capture the actual result, including a failure if it persists.
4. Repeat with both MOV and MP4, selected from Photos and Files. Do not assume the filename extension identifies the actual container.
5. Play the beginning, middle and end; verify audio synchronization, orientation and duration. Confirm codec, resolution, frame rate and actual HDR/Dolby Vision remain those of the input. Check that selected GPS behavior and requested dates are correct.
6. Check one image and a small mixed batch for ordinary processing/export regression. Confirm every selected file is handled and any per-file warning or failure remains visible.

A source-level metadata match or an Apple reader result does not replace step 3. Public replacement remains on hold until the owner reports acceptance of this candidate. If the camera row still fails, retain the current public delivery and investigate the new evidence without claiming this test candidate fixed Photos.
