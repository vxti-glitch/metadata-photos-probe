# Native media and path review (13 October 2026)

This is a source review of the current working tree based on commit `1bbd62e`. It is not an iOS build, a simulator run, a physical-device run, or a claim that the private Photos MOV failure is fixed. The canonical Swift changes and new tests were inspected; they have not been executed on this Windows host.

## Release-significant findings

I found no further P0/P1 issue in the reviewed Swift paths. The following preservation gaps in the committed baseline are addressed by the pending working-tree edits and require a successful macOS test/build run before handoff:

1. `MediaIntegrity.compareMetadata` previously converted known non-target metadata, location, and ImageIO differences into `notChecked`, allowing acknowledgment and export. The working diff restores `failed`, which makes `MetadataEngine.processMetadataPatch` reject the output. `testFullPatchRejectsUnrequestedMetadataAndLocationChanges` covers an ISO-only request with a deliberately changed exposure or GPS value.
2. The committed comparator exempted every video date whenever one date was selected. The working diff limits that to the selected `createDate`/`movieCreateDate` or `modifyDate`/`movieModifyDate` alias pair. `testSelectedMovieDateDoesNotExemptOtherHeaderDates` checks that an unexpected track modification date fails while a valid edit passes.
3. The committed comparator exempted all GPS values when one coordinate was selected. The working diff retains unselected latitude, longitude, and altitude as comparison targets. `testMapCoordinateEditDoesNotExemptUnselectedAltitude` covers an unexpected altitude change after a map-style latitude/longitude edit, with a valid control.

These tests compare deliberately tampered output against a narrower expected patch. They prove the regression gates on controlled media if they pass; they do not establish preservation for arbitrary originals.

## Writer and native-store observations

- `MetadataEngine.processMetadataPatch` validates the patch, rejects same-file/output collisions, inspects before and after, checks selected readback, rejects integrity mismatch, and removes an unsuccessful output. The session store separately hashes the immutable source and output, refuses any failed integrity check, and recomputes a recovered comparison before export.
- JPEG edits replace the EXIF APP1 region and retain other bytes. The JPEG inventory rejects unqualified auxiliary/trailing structures. PNG edits replace or insert only `eXIf`; the layout reader validates every chunk CRC and the verifier hashes all non-`eXIf` chunks. Selected removal with competing XMP/IPTC/text metadata is refused.
- HEIC editing requires a bounded, unique existing Exif item and qualified locator. The writer retargets that item, compares all non-Exif item hashes and the item graph, and refuses unqualified container layouts. Typed edits scrub retired Exif bytes or refuse unsafe in-meta storage. Opaque auxiliary/HDR semantics remain explicitly incomplete.
- MOV/MP4 writing accepts a bounded self-contained subset, preserves original `mdat` positions, checks sample/chunk extents, and refuses unknown relocation-sensitive layouts. The integrity pass compares AVFoundation-exposed encoded samples, timing, format, transforms, tracks, and duration. Opaque and invisible track semantics remain incomplete.
- `NativeSessionStore` derives source/output paths from UUIDs and closed extensions, confines them under a canonical root, refuses symlinks and nonregular files, bounds sizes and journal contents, and checks hashes before processing/export. I found no concrete traversal, arbitrary-path export, or failed-check acknowledgment bypass in the reviewed store and bridge.
- The map picker now requires an actual valid pin before Apply and carries the selected System/Light/Dark appearance to the native sheet. The Swift bridge validates the bounded appearance value and uses a fixed safe message for opaque location restrictions. The map row still cannot safely change coordinates of a movie containing opaque legacy `loci` unless the user explicitly sets or removes altitude too; the focused user-facing message now explains that route. Timed metadata tracks remain intentionally blocked for location edits.

## Verification still required

Run the complete Swift `ProbeCore` and iOS `RunnerTests` suites, including the new comparison and map tests, on the release macOS toolchain. Inspect the exact CI source SHA and IPA manifest. The new synthetic 4K/H.264/AAC fixture checks short encoded media and reports host time only; it does not measure long-video memory, thermal behavior, HDR, or iPhone Photos integration. A correctly signed device candidate and disposable real files remain necessary for the private Photos MOV reproduction, GPS display, Files export, playback, and Photos acceptance.
