# Metadata Editor

A native iOS metadata manipulation suite built with **Flutter** and a high-performance **Swift Core Engine** (`ProbeCore`). Designed for photographers, security researchers, and media professionals who require granular control over image and video metadata without risking compression loss, pixel degradation, or color shifts.

---

## Overview

Metadata Editor provides non-destructive, bit-accurate inspection, modification, and batch processing of media metadata. Unlike general-purpose tools that re-encode media streams during export, Metadata Editor operates directly at the container and chunk level: image raster data and video sample tables remain completely untouched.

### Core Features

- **Format-Native Metadata Editing**: Granular control over EXIF, TIFF, XMP, and QuickTime user-data atoms.
- **Zero-Degradation Engine**: Strict byte-for-byte stream preservation. No pixel decoding, re-encoding, or color profile shifts.
- **Researched Device Catalog**: Over 40 production camera profiles and 140+ lens configurations across Apple iPhone, Google Pixel, and Samsung Galaxy devices.
- **Batch Processing**: Simultaneous multi-file queue editing with progress tracking, non-blocking cancellation, and individual retry capability.
- **Configurable Randomization**: Realistic date, time, and GPS coordinate randomization within user-defined bounds and radii.
- **Preset Management**: Save and export reusable metadata recipes as validated JSON presets.
- **Collision-Safe Export**: Automatic output organization into a dedicated `Processed Media` directory with sequential `IMG_####` naming.
- **Privacy-First Architecture**: 100% on-device local execution. Zero network calls, zero telemetry, and zero third-party tracking.

---

## Container Support & Preservation Guarantees

| Format | Readback Scope | Write Strategy | Integrity Verification |
| :--- | :--- | :--- | :--- |
| **JPEG** | EXIF, TIFF, GPS, IPTC | ImageIO destination copy + APP13/Photoshop block preservation | Bit-exact compressed scan validation |
| **HEIC** | Primary item EXIF/XMP | In-place item property rewrite without decoding tile data | Native ImageIO round-trip readback |
| **PNG** | eXIf, tEXt, zTXt, iTXt | Chunk-level replacement bypassing raster pipeline | Bit-for-bit `IDAT` checksum equality |
| **QuickTime MOV** | `moov.udta`, `keys`, `ilst` | Clean `moov` atom relocation; old atom zeroed as `free` box | Byte-for-byte `mdat` media stream equality |
| **MP4** | ISO Base Media metadata | Standard box parser with strict sample-table validation | Complete video/audio sample table preservation |

> [!NOTE]
> **QuickTime Container Compatibility**: The video engine natively supports iOS camera structures including `csgm` (Compact Sample to Group) sample table boxes while strictly rejecting unverified or malformed sample atoms.

---

## Architecture

The application is structured into two decoupled layers communicating over a typed platform channel:

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
3. **ProbeCore Swift Engine (`Sources/ProbeCore/`)**: A standalone Swift package implementing zero-allocation container parsers, byte-level integrity verification, and atomic disk writes.

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

- **Completely Offline**: The application makes no network requests. All metadata operations and container transformations occur entirely within the local application sandbox.
- **Non-Destructive**: Input media files are treated as read-only streams. Output files are written to isolated directories and never overwrite source assets.
- **Zero Credentials**: The application requires no cloud logins, Apple ID tokens, or third-party service authentications.

---

## License

Proprietary software. All rights reserved.
