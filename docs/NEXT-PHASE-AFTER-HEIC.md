# Next plan after the physical HEIC success

The 0.2.1/build 3 report confirms actual HEIC camera make/model/lens writing and exact native readback on the primary physical iPhone. All eight staged checks pass; source/output non-EXIF item bytes, properties, exposed location, orientation and presentation match. The user's Photos screenshot shows the requested camera/lens, the location map and no unwanted source label. This is positive evidence for on-phone HEIC processing and the assisted Files/Safari/iCloud workflow for this case, not public-native attribution suppression or universal quality certification.

The report's exporter state is canceled/dismissed, with no returned-original or manually recorded UI observations. Accept the screenshot/user evidence separately; do not turn the JSON into a complete upload or synchronized-byte certificate. The original report and screenshot stay local and are not uploaded to CI. Opaque MakerNotes and HDR appearance remain unqualified.

## 1. Finish the smallest video processing gate

Use the current installed build first. No new feature build is required just to run these tests.

- Controlled MP4: choose `original.mp4` from the supplied fixtures, perform Stage B with changed make/model and no lens, inspect exact readback and integrity, export to Files and upload manually through Safari/iCloud.
- Real camera MOV: record a short disposable portrait video with sound, import its original without conversion, perform the same metadata change and assisted upload. Confirm the actual container/codec; H.264/HEVC alone are not filename formats. The silent synthetic video cannot qualify audio, portrait transforms or genuine camera tracks.

For both, require correct exposed embedded tags, no failed integrity checks, retained duration/rotation, playable picture and sound where present, and no unwanted source label in the synced Photos result. Record whatever camera fields Photos actually displays; absence of a field is not automatically a metadata-writing failure. Unsupported structures become focused compatibility cases using the actual file, without transcoding or dropping tracks.

Earlier unchanged MP4/MOV uploads already supplied attribution observations. These tests must perform actual on-phone metadata changes; do not repeat unchanged-file controls. Optional returned-original inspection can strengthen post-upload preservation evidence without creating another Photos asset. It is not a prerequisite to repeat the already successful HEIC demonstration.

## 2. Agree the supported save experience

Recommend retaining SwiftUI and the separate Swift engine. If the owner accepts **edit locally -> export to Files -> manual Safari/iCloud upload -> sync to Photos**, it is a viable phone-only product candidate subject to the remaining gates. It requires an iCloud account, network access, explicit browser steps and synchronization; processing itself stays local.

The original specification's direct Photos-save requirement is not silently changed. A successful website import does not establish that one-tap PhotoKit saves can omit source attribution. If direct native saving with no label remains mandatory, that requirement stays unresolved and must be investigated before promising the full product. Do not use private APIs, forged system identity or undocumented iCloud upload endpoints.

## 3. First product milestone, only after explicit implementation approval

Build the single-file editor foundation: Photos/Files import, metadata inspection, manual editing of individually qualified fields, immutable originals, strict readback/integrity gates and the approved export experience. Expand beyond make/model/lens in controlled groups: dates/time zones, GPS, exposure and other camera fields, with format-specific type/range rules and clear unsupported outcomes. Preserve the original planning research and the corrected native architecture.

Qualify PNG separately because it remains in the original product specification. Introduce selective metadata removal only after verifying residual/opaque information: the current HEIC writer retains unused old EXIF bytes and therefore is not a removal/privacy implementation. Add saved presets/camera profiles, configurable randomization and bulk processing after the single-file engine and recovery/cancellation flow pass their own acceptance gates. Live Photo conversion, video timeline editing and Zlarp integration remain out of this next milestone.

No full-editor development is authorized by this planning update. Stop for the two video results and the save-workflow decision; then obtain explicit approval for the implementation milestone.
