# Physical iPhone test protocol

Primary target: iPhone 15 Pro Max, reported iOS 27.2. Record Settings → General → About version/build and whether the build is beta/public. The probe logs hardware/OS/app identifiers; record the signing/installation method separately. Other devices/builds are separate evidence.

## Protect the controls

Use disposable, non-sensitive media. Keep independent originals. Never test existing-asset editing on irreplaceable library assets. The probe refuses previous adjustments and Live Photos. It does not erase a Photos original or remove app-origin information.

For JPEG, HEIC, MP4 and MOV, obtain:

1. A small controlled original and an edited counterpart with recognizable different camera fields. The builder's synthetic fixture ZIP is suitable for ordinary format tests where its manifest says generation/writing succeeded.
2. Fresh disposable Camera-origin controls and existing successful Windows→iCloud-upload controls where available.
3. An already app-attributed control. Record its initial label before testing: retaining no label and removing an existing label are different questions.
4. Additional real iPhone HEIC/HDR, HEVC/HDR MOV and rotated samples. Synthetic H.264 clips do not certify those structures.

The generated fixtures contain simulated camera metadata and are not authentic captures. Their manifest reflects macOS engine results, not iPhone behavior. If a counterpart was not generated, use an independently validated counterpart or record the operation unsupported; do not substitute a recompressed conversion.

Do not construct all existing-asset controls using the probe's new-asset route: that can give them this app's source association and contaminate the comparison. If duplicating a control, check its displayed source first.

## Stage A: test PhotoKit with prepared files

For each of the four formats:

1. In the probe, choose a source from Files or Photos. Record its baseline origin. For existing edits, select the actual controlled Photos asset, grant read/write access including that asset, and retrieve its original/current resource deliberately.
2. Open the control in Apple Photos. Record the camera/lens fields, date/location and exact source label, including absence. Retain a screenshot with a case ID.
3. Choose **Stage A · prepared files** and select the matching edited counterpart from Files. Review source/output metadata and integrity checks. If using a no-op, choose **Use unchanged source** instead.
4. Run **New asset: file resource**. If integrity is incomplete, diagnostic saving requires explicit acknowledgement; this does not constitute a quality pass. Known mismatches block saving.
5. Record the new asset identifier, save outcome, resource inventory, saved camera checks and integrity. A confirmed save with failed readback is incomplete. **Retry resource readback** does not create another asset.
6. Inspect the result in Apple Photos → Info. Record camera values and source attribution in the app's observation form. Do not infer attribution from sourceType, file tags or a successful save.
7. Repeat with **New asset: file factory** using a fresh deliberate trial. The two routes are not assumed equivalent.
8. Test **Edit selected existing asset** only on an eligible disposable asset. Consent explicitly; the app requires the staged baseline to match PhotoKit's editing input. It refuses prior adjustments, nonupright data, missing exact rendered type, conversion or non-file-backed video. Record refusal as an outcome, not as a missing success badge.
9. Compare original/current resources after an existing edit. The original is expected to retain original metadata. Inspect whether Photos displays the new camera values or continues to show the original camera. If testing Revert, use Photos' public UI on the disposable control and record the result; the probe does not promise unlimited history.

Repeat the candidate successful route at least three times for each format/import path/source origin being claimed. Use unique case IDs and record duplicate/deduplication behavior.

## Stage B: change metadata on the phone

Only after reviewing Stage A for this format and route:

1. Acquire a new controlled source; select **Stage B · on-device change**.
2. Select the intended route and acknowledge the Stage A review. This checkbox is a user report, not automatic qualification.
3. Set camera make/model different from the source. For an image, optionally set lens. For video, leave the unsupported lens operation out.
4. Run **Write camera metadata on this device**. The app writes a separate file, reads back intended values and compares media. It does not fall back to encoding or format conversion.
5. Review the result, save through the chosen PhotoKit route, and repeat all resource/UI observations. A prepared-file save does not count as this test.
6. Share staged media to Files if needed for independent tooling. The share sheet excludes Save to Camera Roll so that this export does not accidentally become an undocumented fourth Photos-save route.

## Observation phases and pass criteria

Record each phase independently: immediately after save, after closing/reopening Photos, and after iCloud sync settles. Include camera text, attribution text/absence, screenshot reference and quality notes. A temporarily missing label while indexing is not a dependable pass.

Check original-format retention, compressed payload/sample comparisons, orientation, dimensions, alpha if applicable, ICC/color/HDR, HEIC auxiliary data, playback/seeking, duration and audio. Unknown HEIF/container/HDR checks remain unknown even if a preview looks correct. Verify that the staged source was unchanged.

Check permissions denied/limited, cloud-only acquisition, cancellation, low storage and interrupted save. Do not automatically repeat a save whose result is unknown: first inspect the library. The app records commit intent/identifiers and disables repeating the same output automatically.

Outcomes:

- **Candidate pass:** on-phone processing, correct Photos camera display, absent unwanted attribution and sufficient independent integrity evidence for the exact format/route/build.
- **Conditional:** only existing edits or some formats work. This is not full Files→new Photos feasibility.
- **Failure:** incorrect camera display, unwanted attribution or quality/payload loss.
- **Inconclusive:** no hardware observation, unresolved integrity category, missing resource readback or unstable indexing result.

## Return results

Export the evidence JSON locally, review it for filenames/GPS/asset identifiers, and share only controlled cases. Attach separately retained Photos Info screenshots using the references in the report. Include the build/installation channel and fixture manifest. No report is uploaded by the app.

After handing over this prototype, development stops until these physical-device results are reviewed. A simulator, code review, unsigned archive or successful CI run cannot establish label-free Photos behavior.

