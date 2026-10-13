# Metadata, preservation and Photos acceptance

All edits use the existing metadata-only writers and immutable copied originals. No format conversion, track dropping or encoding fallback was added. A known mismatch blocks output/export. Opaque or unavailable evidence remains incomplete and requires explicit acknowledgment; this does not make it fully verified.

## Supported field matrix

The Swift registry and per-format capabilities are authoritative. The following groups summarize them; they are not claims about what Photos displays.

| Field group | JPEG / HEIC / PNG | MOV / MP4 | Qualification |
|---|---|---|---|
| Make, model, lens model | Supported | Supported movie/track fields | Bounded primary readback plus independent Apple reader where exposed |
| Lens make, physical focal length | Supported | Not advertised | Video supports its separate 35 mm equivalent field |
| ISO, shutter time, aperture, 35 mm focal length | Supported | Supported track fields | Every exposed video track must read back the selected value |
| Exposure compensation, metering, flash | Supported | Not advertised | Original values/removals and numeric bounds covered in TIFF tests |
| Capture date and timezone | EXIF wall time with offset fields | Explicit ISO 8601 time zone; movie/track/media headers | Keep is per destination; selected header aliases only are exempt from comparison |
| Latitude, longitude, altitude | Supported | Coupled coordinate tuple | Opaque legacy tuples require explicit action for all components; timed metadata edits are refused |
| Image direction | Supported | Not advertised | Unselected GPS components remain comparison targets |
| Software, title, description, artist, copyright, keywords | Supported | Supported fields where in registry | Independent reader may omit some public dictionary mappings; missing secondary evidence stays incomplete |
| Host computer | Supported | Not advertised | Primary TIFF readback; independent-reader exposure may be limited |
| Orientation, resolution, codec, frame rate, HDR | Preservation targets, not editing features | Preservation targets, not editing features | No invented orientation/codec editing capability |

## Preservation evidence

| Format | Automated evidence | Important limits |
|---|---|---|
| JPEG | Scan/coding signatures, application/profile bytes, dimensions/orientation, non-target ImageIO properties, selected typed readback | MPF/JUMBF and unqualified structures refused; opaque maker notes/XMP are not arbitrary-original certification |
| PNG | Exact all non-eXIf chunks including IDAT, alpha, palette and color profile; RGB/RGBA/indexed fixtures; typed TIFF readback | Competing text metadata restricts removal; opaque EXIF/SubIFD graphs remain incomplete |
| HEIC | Non-Exif item hashes, primary/item IDs, graph/property digest, source immutable, selected EXIF readback | Existing qualified Exif locator required; arbitrary auxiliary/depth/HDR semantics need fuller independent and device evidence |
| MOV / MP4 | Every exposed encoded sample/timing/format/transform, track inventory, self-contained chunk/offset coverage, metadata readback, source hash | Opaque/AVFoundation-invisible track/HDR/edit-list semantics remain incomplete; unsupported boxes/fragmented/protected sources are refused |

Tests include metadata addition and change, selected removal, conflicting representations, typed range errors, invalid CRC/offset/container inputs, missing outputs, immutable sources and recovery/export gates. New controls deliberately alter unselected metadata/date/altitude and require failure. The short synthetic 4K H.264/AAC case and existing eight-second multichunk video are host controls. Long 4K, device RAM/temperature, Dolby Vision/HDR, low storage and provider background behavior remain hardware gates.

## Photos compatibility matrix

Workflow: import original -> prepare/review edits -> create copy -> inspect qualification -> explicitly accept any listed limits -> export to Files -> user-operated Safari/iCloud Photos upload where supported -> wait for sync -> inspect Photos Info and playback. Do not substitute a direct PhotoKit save as a claimed attribution solution.

| Format | Embedded output supported in app | Files export | iCloud upload / Photos Info / provenance |
|---|---|---|---|
| JPEG | Synthetic automated qualification | Native export gates tested | Physical/provider acceptance pending |
| HEIC | Qualified container subset | Native export gates tested | Physical/provider acceptance pending; auxiliary/HDR evidence separate |
| PNG screenshot | Synthetic RGB/RGBA/indexed qualification | Native export gates tested | Upload support and camera/exposure display need actual observation |
| MOV | Qualified nonfragmented subset | Native export gates tested | Exact previously reported Photos-imported private MOV failure remains unreproduced |
| MP4 | Qualified nonfragmented subset | Native export gates tested | Physical/provider camera/GPS/time/playback acceptance pending |

Apple's uploader and Photos indexing can differ by provider, system version and format. Verify actual supported ingestion rather than rename or convert a refused file. Photos may omit supported file tags in its UI. Provenance is system-managed and cannot be certified from PHAsset.sourceType, an EXIF change or successful file export. No Photos screenshots or hardware success were fabricated.
