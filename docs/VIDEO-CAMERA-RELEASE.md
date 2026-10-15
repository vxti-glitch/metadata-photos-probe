# Video camera metadata replacement release

## Scope

The owner requested correcting the Apple Photos video camera information and replacing the IPA on the existing public Zlarp listing. The product remains `metadata-editor` at $25 per month. This authorizes replacing the delivery file; it does not require changing the existing customer listing, screenshots, pricing, licensing, or Pro Graphite interface.

The replacement candidate keeps marketing version **1.0.11** and advances to build **21**. Record the full frozen commit, exact successful push CI run, artifact ID and SHA-256 in the generated owner release report. Never infer the actual binary version from a folder name: the historical folder named `Metadata-Editor-Release-v1.0.12-video-aligned-99eae00` actually contains version 1.0.11 build 20.

## Evidence and limits

The owner supplied a processed-video Photos screenshot showing "No camera information" and a native-camera reference showing Apple iPhone 15 Pro Max and Main Camera. A screenshot alone does not identify which embedded key Photos consumed.

Local inspection of the supplied native reference MOV found primary make/model in the QuickTime `mdta` metadata channel. Its lens description and 24 mm focal value provide concrete comparison data. The reference aperture was read as `F1.78`, which requires normalization rather than a plain floating-point parse. This is evidence from one supplied file, not a claim about all iPhone videos or Photos versions.

The writer must consistently write and read back requested make, model, lens and compatible focal/aperture fields without changing encoded video/audio samples, codec, resolution, HDR data or tracks. Compatibility metadata must not be described as a guarantee that Photos will use a particular legacy `udta` key. Existing source evidence and payload checks remain separate from the actual Photos display result.

User-supplied MOV and MP4 files remain local. Do not copy them, their filenames, GPS or other private metadata into Git, CI, release packages or the public listing. Use synthetic fixture media for checked-in regressions.

The first candidate CI run confirmed independent AVFoundation camera make/model readback in MOV, but rejected an assumption that MP4 exposes classic QuickTime user data. MOV therefore requires both channels in the regression; MP4 requires its primary keyed metadata channel. Neither test uses the writer's parser as a substitute for Apple's reader. This format distinction does not establish Photos presentation.

## Build and package

The existing `ios-editor.yml` workflow runs the pinned Flutter/Swift checks, hosted native checks, simulator launch and arm64 device archive. Preserve that workflow. Local helpers under `build/audit/video-camera-release/` must bind downloaded artifacts, IPA metadata, source ZIP blobs, recorded checks and hashes to the exact frozen successful push run.

Create a new release folder; preserve the earlier `fa1e944` and `99eae00` packages. Do not reuse the misleading versioned folder name. Do not ship a binary under the same build identity as the previously listed build 20.

The artifact is unsigned and requires authorized sideload signing. Neither Zlarp licensing nor successful CI proves installation. User-reported prior testing is recorded as owner evidence; it does not establish physical-device behavior of this replacement.

## Public listing and verification

The existing public screenshots may remain because the interface is unchanged. Their provenance remains the previous build 20; do not relabel them as renders from the replacement source. Customer copy must omit build counts, source hashes and internal workflows. Preserve the regular Contact support row and existing licensing.

After upload, read the live delivery configuration back and verify the stored candidate identity or uploaded-file digest where the service exposes it. Preserve rollback identity for the previously listed IPA. A public URL alone does not prove the correct bytes were attached.

The acceptance check for this issue is to process a representative video, export the actual copy, import it through the owner's normal Photos workflow, and inspect the camera row and lens description. Check playback/audio synchronization and compare real codec/resolution/HDR with the source. Do not claim that H.264 became HEVC or that SDR became Dolby Vision merely by editing metadata. No newly observed physical-device outcome is recorded in this document.
