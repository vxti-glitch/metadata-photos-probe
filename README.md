# Metadata Editor

An iOS metadata editor built with **Flutter** and the canonical **Swift engine** (`ProbeCore`). It writes separate output files, reads back requested fields, and checks media preservation before allowing export. Supported container layouts and verification limits are described below; physical-device behavior requires separate validation.

---

## Overview

Metadata Editor inspects, modifies, and processes media metadata in batches. The engine edits supported container structures without decoding and re-encoding media. Unsupported layouts are refused. A known integrity mismatch blocks output; an incomplete comparison requires explicit acknowledgment before export and remains incomplete afterward.

### Core Features

- **Metadata Editing**: Supported TIFF/EXIF/GPS and QuickTime movie/track fields, with selective removal where safe. Competing XMP/IPTC/text namespaces are preserved or cause removal to be refused.
- **Media Preservation Checks**: Compare compressed payloads and presentation information where qualified; disclose checks that cannot be completed.
- **Researched Device Catalog**: Over 40 production camera profiles and 140+ lens configurations across Apple iPhone, Google Pixel, and Samsung Galaxy devices.
- **Batch Processing**: A sequential queue with progress, cancellation, and individual retry.
- **Configurable Randomization**: Realistic date, time, and GPS coordinate randomization within user-defined bounds and radii.
- **Preset Management**: Save and export reusable metadata recipes as validated JSON presets.
- **Export**: `IMG_####` filenames, a Files export picker, and optional automatic saving of fully verified results into `Processed Media`. Incomplete results remain app-owned until acknowledged for explicit export.
- **Local Processing**: Media processing runs on the device. Importing a user-selected cloud resource can require a provider download; processing does not upload media or telemetry.

---

## Container Support & Verification Limits

| Format | Readback Scope | Write Strategy | Integrity Verification |
| :--- | :--- | :--- | :--- |
| **JPEG** | Supported TIFF/EXIF/GPS fields | Bounded APP1/TIFF replacement; legacy camera probe uses ImageIO copy and APP13 preservation | Compressed scans/coding segments and exposed properties; opaque metadata remains incomplete |
| **HEIC** | Supported fields in an existing unique Exif item | Append replacement Exif and retarget its locator without decoding image items | Non-Exif item hashes, item graph/properties and ImageIO readback; arbitrary HEIF graphs remain incomplete |
| **PNG** | Supported TIFF/EXIF/GPS fields in eXIf | Chunk replacement; text packets remain unchanged and can prevent safe removal | Non-eXIf chunk hashes and exposed properties; opaque EXIF remains incomplete |
| **QuickTime MOV / MP4** | Qualified movie/track metadata and header dates | Bounded `moov` relocation; retain media offsets and retire the old header | Encoded samples, timing, format, track inventory and targeted readback; opaque/HDR semantics remain incomplete |

Fragmented, protected, externally referenced, ambiguous, or unqualified video structures are refused. Selected metadata removal is refused where duplicate namespaces cannot be scrubbed safely. HEIC Exif inside a `meta/idat` box is currently refused for the full metadata patch path because retired bytes cannot yet be independently scrubbed and verified.

> [!NOTE]
> **QuickTime Container Compatibility**: The video engine natively supports iOS camera structures including `csgm` (Compact Sample to Group) sample table boxes while strictly rejecting unverified or malformed sample atoms.

---

## Architecture

The application has three components. Flutter communicates with the native bridge through a typed platform channel; the bridge calls the canonical Swift package.

```
┌────────────────────────────────────────────────────────┐
│                      Flutter UI Layer                  │
│       (Reactive Queue, Forms, Inset-Grouped Modals)     │
└───────────────────────────▲────────────────────────────┘
                            │ MethodChannel Bridge
┌───────────────────────────▼────────────────────────────┐
│                    Native Media Bridge                 │
│         (Input Validation, File Staging, Dispatch)     │
└───────────────────────────▲────────────────────────────┘
                            │ Swift Package Import
┌───────────────────────────▼────────────────────────────┐
│                   ProbeCore Engine                     │
│  (Container Writers, Chunk Parsers, Integrity Sweeps)  │
└────────────────────────────────────────────────────────┘
```

1. **Flutter Presentation Layer (`editor/lib/`)**: Provides an iOS Inset-Grouped interface with dark navy styling (`#0E1115` / `#162032` / `#9CB5FF`), case-insensitive live search, and reactive batch queue state.
2. **Native Platform Bridge (`editor/ios/Runner/`)**: Validates input boundaries, coordinates sandbox staging in `NSTemporaryDirectory()`, and executes file I/O on background threads.
3. **ProbeCore Swift Engine (`Sources/ProbeCore/`)**: A standalone Swift package with bounded container parsers, file-backed writers, metadata readback, and media integrity comparisons.

---

## Device Catalog

Metadata Editor includes an authentic device catalog (`editor/assets/camera_profiles.json`) sourced from published manufacturer specifications:

- **Apple**: 28 iPhone configurations spanning iPhone 11 through iPhone 16 Pro Max, including Main, Ultra Wide, Telephoto, and TrueDepth Front cameras with true physical and 35mm-equivalent focal lengths and maximum apertures.
- **Google**: 7 Pixel configurations covering Pixel 6 through Pixel 8 Pro.
- **Samsung**: 7 Galaxy S-series configurations covering S21 through S24 Ultra.

---

## Building and Verification

### Prerequisites

- macOS 14+ (Sonoma) or higher
- Flutter SDK `3.47.6`
- Xcode `16.0+` (iOS SDK `17.0+`)
- CocoaPods `1.15+`
- Python `3.10+` (for package and manifest verification suites)

### Local Test Execution

Run the complete verification suite:

```bash
# 1. Flutter static analysis & tests
cd editor
flutter analyze
flutter test

# 2. Python package and build verification (from project root)
cd ..
python scripts/editor-package-tests.py
python scripts/test-build-scripts.py
```

### Building the iOS Package

Automated builds are configured for Apple Silicon runners via `codemagic.yaml` or local compilation:

```bash
# Compile and archive the release application (macOS)
bash scripts/build-editor-macos.sh
```

---

## Privacy & Security

- **Local Metadata Processing**: Container transformations run in the local sandbox. Photos/Files providers may download selected cloud resources.
- **Non-Destructive**: Input media files are treated as read-only streams. Output files are written to isolated directories and never overwrite source assets.
- **Zero Credentials**: The application requires no cloud logins, Apple ID tokens, or third-party service authentications.

---

## License

Proprietary software. All rights reserved.
