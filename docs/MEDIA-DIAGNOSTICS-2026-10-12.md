# Video investigation and PNG screenshot coverage

Version 1.0.8, build 14.

The owner reported an integrity failure after importing a video from Photos. A supplied local sample was structurally inspected without uploading it: its container is QuickTime MOV with H.264 video and AAC audio. The existing 1.0.7 error hid the failing check names. Its exact device failure has not been reproduced on the available macOS/iOS fixtures; no speculative writer workaround or weakened verification was added.

## Changes

- A compact inline error message replaces the large error-code badge, heading and filled help button. Details and dismissal remain accessible. Full guidance stays in Settings and rejected outputs remain unavailable for export.
- Integrity errors retain a bounded list of known check identifiers. Tapping Details displays their safe labels immediately in the latest-issue card; arbitrary stored error text is never rendered. No user filename, metadata values, GPS values, sample contents or raw native error descriptions are included.
- PNG Photos/Files import and original-format eXIf editing already exist. Added valid metadata-free RGB, transparent RGBA and indexed screenshot fixtures verify full camera/date/exposure editing, selected removal, exact compressed chunks and unchanged originals. Opaque text removal remains explicit and fail-closed.
- Added PNG native import, reserved IMG_####.PNG name, processing, acknowledgment, export and recovery coverage.
- Expanded automatic MOV/MP4 metadata tests cover no source tags, H.264/AAC, fast-start layout, exposure fields, dates, software and lens metadata. A generated eight-second interleaved video/audio fixture asserts multiple chunks on both tracks before checking every encoded sample. Native iOS tests exercise the full automatic patch and safe failure diagnostics.

## Acceptance

Report Windows Flutter, canonical Swift, hosted native, simulator and unsigned archive results separately. The provided private sample is not a CI fixture. A successful synthetic test does not establish that the exact Photos original succeeds on the owner's device. The updated build's Details can identify the failing check if the problem persists; its next screenshot is needed to diagnose an unreproduced physical-device failure.
