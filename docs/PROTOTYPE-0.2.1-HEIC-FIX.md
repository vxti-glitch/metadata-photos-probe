# Prototype 0.2.1 / build 3: shared HDR HEIC metadata

The user's real HEIC failed the 0.2 writer before creating output: its unique EXIF item describes both the primary image and a tone-map (`tmap`) representation. That representation derives from the primary/base image and an auxiliary gain-map grid. The original singleton-only check incorrectly classified this particular relationship as ambiguous. The photo and its EXIF/GPS payload stay local; only invented fixtures and generic relationship tests are sent to cloud builds.

Apple describes Adaptive HDR HEIC on iPhone 15/15 Pro as containing a TMAP recipe and gain map despite exposing one image through ImageIO. [Apple WWDC24](https://developer.apple.com/videos/play/wwdc2024/10177/) The public shared HEIF reader in libavif checks EXIF association by membership in the described destinations and validates ordered tone-map inputs, base then gain map. [Pinned maintainer source](https://github.com/AOMediaCodec/libavif/blob/0061e03104b959e3aaad73f7d48e968469fff16b/src/read.c), [AOM AVIF 1.2 tone-map reference to HEIF](https://aomediacodec.github.io/av1-avif/v1.2.0.html#tone-map-derivation)

## Narrow change

- Retain the existing single-primary EXIF case.
- Additionally permit one EXIF descriptive reference to exactly the primary and one directly related tone-map image, in either descriptive destination order.
- Require the tone-map's sole outgoing derived-image reference to be exactly `[primary, gain map]`, with one gain-map auxiliary reference back to that primary. Inputs must be coded HEVC items or direct grids of unique coded HEVC tiles. Unrelated, duplicate, cyclic, missing and unqualified relationships remain refused.
- Retain every reference/property byte and non-EXIF item payload. The existing writer retargets only the EXIF item; it does not decode/re-encode pixels, flatten HDR, alter the tone-map recipe or remove the gain map.
- Preserve exact ImageIO camera readback and independent media comparisons. Exposed GPS/orientation and original TIFF bodies remain checked. Shared camera changes affect both described representations, explicitly disclosed in integrity limitations. Original unused EXIF bytes remain in the file; this is not metadata removal or authenticity verification.
- Clear an earlier staged result before starting another write and end the progress message when an operation fails. Historical trial files remain available, but a failed new write cannot offer old output as its result.

Synthetic graph tests cover both TIFF byte orders and both EXIF destination orders, raw relationships/properties, all non-EXIF item bytes and source immutability. Negative cases cover malformed/unrelated/duplicate/cyclic relationships and unqualified types. The synthetic relationship fixtures are not playable Adaptive HDR photos; existing ImageIO tests exercise independently encoded HEIC. Cloud success cannot establish this actual photo's native readback or HDR appearance.

## Phone retry after signing/installing the update

1. Confirm **0.2.1 / build 3**, using the same authorized signing method as before. The cloud-produced IPA is unsigned.
2. Select the same failing HEIC through **Choose source from Files** if available. To compare the original Photos acquisition separately, select the original disposable photo through Photos and **Retrieve original Photos resource**. Keep the acquisition route identified.
3. Use Stage B with your completed baseline acknowledgement. Enter a different ordinary ASCII make/model and optionally lens, then **Write camera metadata on this device**.
4. If another error appears, stop and retain its exact text/evidence. Do not convert to JPEG or use the prior staged result.
5. If readback succeeds, inspect requested fields, location and integrity. All known mismatches remain blocked; opaque MakerNotes/HDR semantics remain incomplete.
6. **Save a copy to Files**, upload that exact copy manually through Safari/iCloud, then inspect camera information, unwanted source label, location, orientation and HDR appearance. Record the actual observation and export evidence. Optional returned-original inspection can compare the synced file without another Photos save.

This is a bounded compatibility fix, not a claim that direct app saves avoid attribution or that arbitrary Adaptive HDR media is fully qualified. Full editor development remains on hold for physical-device results. See [validation status](VALIDATION-STATUS.md) for the exact tested revision/run and remaining gates.
