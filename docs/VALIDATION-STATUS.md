# Validation status

Validated October 7, 2026 (America/New_York). [GitHub macOS run 37722017789](https://github.com/vxti-glitch/metadata-photos-probe/actions/runs/37722017789) **succeeded** for source commit `ae139066fed4c10ae5f3a8c9141dc4d2a905608c`. Its UTC logs are dated October 8. The signed-export job was skipped.

| Layer | Current evidence |
|---|---|
| Windows build/signing scripts | 11 portable signing-policy tests passed locally and in CI; Python, Bash, YAML and plist checks passed. |
| Swift package / app compilation | Passed on macOS 15.7.9 arm64, Xcode 16.4 (16F6), Swift 6.1.2 driver in Swift 5 language mode, iOS SDK 18.5. |
| Native engine tests | 23 macOS XCTest cases passed. Capability tests explicitly record HEIC/MP4 writer refusal rather than successful camera edits. |
| Hosted iOS app tests | 19 policy/evidence XCTest cases passed on iPhone SE (3rd generation) simulator, runtime iOS 26.2. These do not execute physical PhotoKit save/edit experiments. |
| Controlled fixture generation | Generated original JPEG, HEIC, MP4 and MOV plus a separately labeled undated JPEG control; JPEG/MOV processed counterparts available. All fixture-file SHA-256 values checked after downloading. |
| Device IPA packaging | Generic iOS Release archive passed; downloaded IPA contains an arm64 Mach-O app, minimum iOS 17.0. Unsigned, without a provisioning profile, and **not installable** on an ordinary iPhone. |
| Signing | No signing secrets or signing environment were configured in this repository at verification. Signed export and installation were not tested. |
| Physical iPhone | Not tested. |
| Photos camera display | Not tested on hardware. |
| Source attribution | Not tested; not solved. |
| Full HEIC/video preservation | Not certified; conservative incomplete results remain visible. |

Source verification, compilation, simulated integration and physical-device observations are separate results. No full application scope is authorized.

## Measured media outcomes

These are synthetic macOS fixtures, not iPhone camera captures or iPhone processing results.

| Format | Camera operation | Integrity evidence / limitation |
|---|---|---|
| JPEG (dated and undated controls) | Exact make/model readback passed; lens preservation/editing covered by tests. | Compressed scans/coding, non-target application/color blocks, dimensions, orientation and exposed non-target properties passed. Opaque EXIF/XMP qualification remains incomplete. |
| HEIC | ImageIO copy left the original camera values on this host; exact readback rejected the result and removed the failed output. | Original unchanged. No processed HEIC counterpart or successful on-device write is claimed. Use unchanged controls or independently validated prepared counterparts for Stage A. |
| MP4 | AVFoundation same-container passthrough omitted requested camera tags on this host; readback rejected the result and removed the failed output. | Original unchanged. No processed MP4 counterpart or successful on-device write is claimed. Stage A can still test prepared or unchanged MP4. |
| MOV / H.264 | Exact make/model readback passed. | Source/output encoded bytes, timing, format, transforms, track inventory and duration passed. This final fixture has 646 encoded bytes, 19 sample buffers and four matching empty markers. Opaque container/HDR semantics remain incomplete. |

Earlier runs exposed real implementation issues: compiler type errors, conflated JPEG checks, empty MOV sample markers and unsupported camera writes. Those failures are retained in GitHub history. The final JPEG writer merges only requested tags and restores original leading APP13 blocks through bounded streaming; it does not decode or re-encode scans. Tests cover opaque APP13 preservation, malformed/oversized input cleanup and source immutability. No quality gate was bypassed to enable saving.

Whole-file-identical controls can establish exact byte preservation. For changed files, known mismatches block saving; unresolved structure requires explicit diagnostic acknowledgement. Passing guard/capability tests does not qualify all four native writers.

## Delivered build evidence

The downloaded IPA, archive, source ZIP and fixture ZIP all matched the CI manifest's byte counts and SHA-256 values. The IPA SHA-256 is `e382884050439dbf5297df3c91df1a0c6300924c42fa978ec7bdd3d74db72d1f`.

GitHub artifacts are `probe-unsigned-7-1` and `probe-controlled-fixtures-7-1` (14-day retention). Copies are retained locally under `prototype/dist/verified-ae13906/`. The manifest and full logs accompany the unsigned artifact. Documentation-only handoff updates after this source revision do not change the compiled implementation.

Independent code and security reviews identified and corrected stale readback checks, hidden image-lens state in video edits, historical device-context drift, postcommit journal failure labeling and late Photos acquisition after clearing. The hosted tests include an injected successful commit followed by failed persistence and canceled/stale provider callbacks. Final verification independently confirmed the successful run, test counts, actual SDK/runtime and remaining hardware/signing gates.

## Still required on the primary iPhone

Configure the authorized team certificate/profile and variables using [BUILD-AND-INSTALL.md](BUILD-AND-INSTALL.md), export an eligible signed IPA, install it, then run [DEVICE-TEST-PROTOCOL.md](DEVICE-TEST-PROTOCOL.md). Test all four formats for both new-asset routes and eligible existing edits; record unsupported outcomes rather than substituting conversions. Verify actual Settings version/build, baseline origin, saved-resource camera fields, Photos Info camera display and full attribution text at immediate/relaunch/sync phases.

Neither absence of imported-source attribution nor correct Photos camera indexing has been established. Real HEIC auxiliary/HDR data, audio/metadata video tracks, HEVC/HDR, rotated inputs, cloud-only assets, denied/limited access, low storage, interruption and Photos Revert require the documented hardware matrix. Existing edits may be refused for nonupright, previously adjusted or incompatible rendered content. Development stops at this prototype until the user returns device evidence and authorizes further work.
