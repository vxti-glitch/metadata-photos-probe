# Video Camera Metadata & Apple Photos Alignment Plan

## 1. Defect Analysis & Root Causes

Based on physical device inspection of the edited video (Image 1) versus a genuine iPhone capture (Image 2), three discrepancies were identified in Apple Photos' Inspector sheet:

| UI Element | Current App Output (Image 1) | Genuine iPhone Capture (Image 2) | Root Cause |
|---|---|---|---|
| **Header Title** | `No camera information` | `Apple iPhone 15 Pro Max` | `VideoMetadataWriter` currently writes `make` and `model` exclusively to `moov/meta` (mdta) and strips legacy `moov/udta` atoms. Apple Photos and ImageIO (`CGImageSource`) query `moov/udta/©mak` and `moov/udta/©mod` to resolve the primary device title. |
| **Camera Subtitle** | `iPhone 15 Pro Max back triple camera`<br>`6.765mm f1.78` | `Main Camera — 24 mm f1.78` | Because Apple Photos failed to detect the device model in `udta`, its internal profile mapping could not resolve the lens to `"Main Camera"` or pair it with the 35mm equivalent focal length (`24 mm`). It fell back to printing the raw `lensModel` string and physical focal length. |
| **Location Card** | `Add a location...` | Interactive Map with Pin | Geolocation was either unselected or only written to `com.apple.quicktime.location.ISO6709` in `mdta`. Apple Photos on iOS reads `moov/udta/©xyz` for map indexing. |

---

## 2. Technical Implementation Architecture

### Step 1: QuickTime User Data (`udta`) Dual-Channel Synchronization
In `Sources/ProbeCore/VideoMetadataWriter.swift`:
- Implement synthesis and updating of classic QuickTime `udta` atoms:
  - `©mak` (`0xa9, 'm', 'a', 'k'`): 16-bit length + 16-bit language code + Camera Make string (`Apple`).
  - `©mod` (`0xa9, 'm', 'o', 'd'`): 16-bit length + 16-bit language code + Camera Model string (`iPhone 15 Pro Max`).
  - `©swr` (`0xa9, 's', 'w', 'r'`): 16-bit length + 16-bit language code + Software version string (e.g. `17.5.1`).
  - `©xyz` (`0xa9, 'x', 'y', 'z'`): 16-bit length + 16-bit language code + ISO 6709 location string (e.g. `+37.7749-122.4194+010.000/`).
- If `moov/udta` is missing from the source container, create and insert it.
- Update `retainUserData` to replace or insert these atoms rather than stripping them.

### Step 2: Track-Level Camera Metadata Mirroring
In `Sources/ProbeCore/VideoMetadataWriter.swift`:
- Mirror `com.apple.quicktime.make` and `com.apple.quicktime.model` into video track metadata (`trak/meta`), ensuring both movie-level and track-level parsers detect the camera identity.
- Position `moov/meta` immediately after `mvhd` (matching canonical Apple iOS Camera container ordering).

### Step 3: Lens & Focal Length Mapping
In `Sources/ProbeCore/VideoMetadataFields.swift` and `editor/assets/camera_profiles.json`:
- Confirm that `com.apple.quicktime.camera.focal_length.35mm_equivalent` (`24`) and `org.smpte.rdd18.lens.irisfnumber` (`1.78`) are written to `trak/meta`.
- With `udta/©mak` and `udta/©mod` identifying the device as `iPhone 15 Pro Max`, Apple Photos automatically recognizes the 24mm f/1.78 lens and formats the subtitle as `Main Camera — 24 mm f1.78`.

### Step 4: Geolocation Synchronization
- When GPS coordinates are present in the patch:
  - Format ISO 6709 string (`+DD.DDDD+DDD.DDDD+AAA.AAA/`).
  - Write to `moov/meta` (`com.apple.quicktime.location.ISO6709`).
  - Write to `moov/udta` (`©xyz`).
- When location removal is requested, cleanly remove both atoms.

### Step 5: Media Integrity & Zero-Reencoding Verification
In `Sources/ProbeCore/MediaIntegrity.swift`:
- Verify readback of `©mak`, `©mod`, `©swr`, and `©xyz` in `videoTargetReadback`.
- Ensure zero-re-encoding checks confirm 100% bit-exact media samples (`mdat`), audio/video sample tables, and track structures.

---

## 3. Execution & Validation Plan
1. Update `VideoMetadataWriter.swift` with `udta` atom construction and dual-channel metadata writing.
2. Update unit tests in `VideoMetadataWriterTests.swift` and `ProbeCoreTests.swift`.
3. Run local automated test suites:
   - Swift Core tests: `swift test`
   - Flutter tests: `flutter test` (245 tests)
   - Packaging tests: `scripts/editor-package-tests.py` (28 tests)
   - Build script tests: `scripts/test-build-scripts.py` (11 tests)
4. Package updated release candidate and verify on physical iPhone in Apple Photos.
