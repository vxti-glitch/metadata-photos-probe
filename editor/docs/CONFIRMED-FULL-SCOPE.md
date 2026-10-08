# Confirmed editor scope

The user confirmed the script-derived scope after reviewing the first single-file editor. This document supersedes the restriction to make/model/lens. Preserve the original development plan, iPhone-first research, Flutter architecture addendum and probe evidence as historical technical references.

## Behavior and acceptance

| Requirement | Acceptance |
|---|---|
| Photo camera/exposure | Read and independently verify make, model, lens make/model, host/software, ISO, exposure seconds, aperture, exposure compensation, physical/equivalent focal lengths, metering and flash. |
| Dates and zones | Capture/digitized/modified EXIF dates and offsets; movie/track/media creation/modification dates with explicit UTC conversion. Reject invalid dates instead of silently writing them. |
| Location | Signed latitude/longitude, altitude and image direction with corresponding references. Never bundle the script's personal GPS anchor; location randomization uses an explicit user-provided anchor. |
| Descriptive metadata | Supported title, description, artist, copyright and keyword fields; preserve unrelated fields or refuse unsafe structures. |
| Manual/removal | Every advertised field has deliberate Keep/Set/Remove intent. Readback proves requested values and absence of selected removed fields. Unsupported opaque or duplicate metadata requires a clear error. |
| Profiles | Brand → Model → Camera; researched specifications with provenance. Populate coherent camera values and clear unknown stale camera fields when switching phones. Actual codec/dimensions/frame rate/duration are never fabricated. |
| Randomization | Configurable ISO/shutter/date/software/location options; generate and persist frozen plans separately per item before native writes. Retry uses the same plan. |
| Presets | Durable saved edits/profile settings; import/export versioned validated JSON. No filesystem paths or executable instructions in presets. |
| Bulk | Mixed-format multi-selection, bounded serial processing, per-item errors, cancellation/retry and durable reconciliation after restart. Successful files remain available when another item fails. |
| Names | Native-generated collision-checked IMG_1000–IMG_9999, correct original extension. Internal UUID file identifiers remain private. |
| Interface | Minimal Import → Preset/edit → Process → Export. Optional Details holds readback/integrity reports and downloaded-original verification; failures still block export automatically. |
| Quality | Immutable original; no recompression or automatic format conversion. Compare compressed image data or sample payloads plus presentation, profiles, auxiliary images and audio/track structure. Incomplete verification is disclosed and needs consent; failed checks cannot be overridden. |
| Upload | Export to Files, manual public Safari/iCloud Photos upload and sync. Compare a downloaded **Unmodified Original** with the processed output using exact bytes/SHA-256. Exporter success does not prove upload or attribution absence. |

## Differences from the Windows script

The Python script invokes Windows ExifTool/FFmpeg executables. Their behavior is the reference; the IPA uses a native Swift engine rather than assuming those Windows executables are compatible with iOS.

Originals are preserved. PNG stays PNG, including transparency; quality-100 JPEG conversion would remain lossy. MP4 stays MP4 by default rather than silently remuxing/deleting it. Codec and handler labels remain accurate to the existing media; the script's hardcoded HEVC string does not convert an AVC bitstream. Local time offsets follow the selected date rather than always assuming -04:00.

Video formats do not expose all still-image EXIF fields through supported metadata namespaces. Capabilities are format-specific: aperture, ISO and exposure seconds use Apple's documented video-track QuickTime keys; flash/metering remain still-only. The script itself did not write video exposure fields, but the approved editor adds the supported equivalents. Proprietary MakerNotes are preserved, not falsely advertised as universally editable or fully anonymized. Camera profiles change embedded claims, not the physical origin of a recording.

## Release and physical-device evidence

Require meaningful Swift, Flutter and native bridge/store tests, independent code review, final verification and an actual macOS device archive before packaging. Record source revision and artifact hashes. An unsigned IPA requires the user's signing channel; the simulator cannot validate installation on the iPhone 15 Pro Max running iOS 27.2.

The accepted phone-only iCloud route has positive user observations for prior tests. New full-field exports, video lens display, HDR playback, selected removal and mixed batches require fresh physical-device qualification. Direct native Photos creation is not the accepted no-label route and is not presented as solved. Live Photo conversion, visual video editing, accounts and Zlarp integration remain outside this change.
