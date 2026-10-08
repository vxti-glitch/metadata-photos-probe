# Metadata Editor — Flutter + Swift

Local metadata editing, then **Files → manual Safari/iCloud Photos upload → sync**. The accepted workflow uses the phone after installation. The original SwiftUI probe and earlier research remain preserved as diagnostic references.

## Editor 0.4

Import JPEG, HEIC, PNG, MP4 or MOV from Photos or Files, individually or in batches. Choose Brand → Model → Camera from the researched catalog, configure randomization, or manually Keep/Set/Remove supported fields. Save reusable presets, including profile recipes; import/export validated preset JSON. Process frozen plans, recover/retry unfinished batches, and export collision-checked IMG_#### copies. Original/provider media stay immutable.

Still-image fields cover the supplied script's camera, lens, software, exposure, dates/time zones and GPS operations plus descriptive fields. Movies expose supported QuickTime camera/lens/location/descriptive metadata and movie/track/media dates. Actual resolution, codec, frame rate, duration, HDR and audio are preserved rather than invented. The per-format native registry controls available fields. Camera names that are descriptive rather than captured EXIF literals are identified in optional Details.

PNG stays PNG, preserving transparency and compressed pixels. There is no recompression or automatic format conversion. Known integrity failures block export; disclosed incomplete verification still requires acknowledgment. Selective removal fails safely when competing metadata or unqualified structures prevent proving that a field was removed. Proprietary MakerNotes are not advertised as universally editable or fully anonymized.

The main flow is Import → Preset/edit → Process → Export. Technical reports and exact comparison of a downloaded iCloud Unmodified Original are in optional Details. Preview images are display derivatives and never processing outputs. Photos imports original resources and refuses Live Photos; current Photos adjustments are not silently flattened.

Files export does not confirm an iCloud upload. The app opens the public iCloud Photos page and captures no Apple credentials. Direct native Photos source-label suppression is not claimed. Photos indexing/display, no-label behavior, signed installation and post-upload preservation require the physical iPhone.

## Architecture

Flutter owns form/preset/profile/queue presentation. Swift owns media files, public pickers, the bounded atomic journal, validated writes, independent readback/integrity and export gates. Canonical processing stays in repository-root Sources/ProbeCore through a local Swift package; no copied media engine or media bytes through the channel. See docs/BRIDGE-CONTRACT.md and docs/CONFIRMED-FULL-SCOPE.md.

The catalog has 42 models and 146 camera choices. It is extensible, not every historical phone. Each profile records manufacturer sources; unknown physical focal lengths/software are omitted and stale camera-specific values cleared when switching devices. See docs/CAMERA-PROFILES.md.

## Windows / GitHub IPA builder

Pinned Flutter 3.47.6 / Dart 3.13.5 permits analysis and Flutter tests on Windows. The GitHub macOS workflow runs Swift tests, Flutter checks, hosted native XCTest, simulator launch and a real ARM64 device archive, then packages the unsigned IPA with source revision, catalog hash and artifact checksums. The old native probe workflow is preserved.

Metadata-Editor-UNSIGNED-NOT-INSTALLABLE.ipa needs valid signing through the user's authorized channel. A package and simulator launch do not prove signed installation. Bundle ID com.vxtiglitch.metadataeditor remains separate from the probe.

The neutral product name remains Metadata Editor / Photo & Video Metadata; independent branding is documented under branding/. Zlarp integration, accounts, Live Photo conversion and visual video editing are outside this release. Media, GPS, signing inputs and private reports stay out of source and CI.

See docs/DEVICE-TESTS.md for the new device checklist. docs/VALIDATION.md records historical 0.3 evidence; new 0.4 evidence is recorded separately after verification.