# Video camera compatibility findings

## Observed defect

The owner's processed-video Photos screenshot shows "No camera information" and a raw lens description. A native reference shows the camera model and Main Camera. These are physical observations of earlier files, not proof of the replacement candidate's behavior.

Local inspection of the reference finds movie-level QuickTime mdta make/model, with track-level lens model, a UTF-8 35 mm equivalent value of `24`, and UTF-8 aperture `F1.78`. It does not require classic copyright make/model atoms. The comparison download contains no camera metadata and cannot establish what the earlier processed export contained.

## Candidate changes

- Preserve movie mdta make/model and add synchronized classic udta make/model for parser compatibility. Do not claim Photos exclusively reads either representation.
- Preserve camera-only track bytes. Speculative track-level make/model mirroring was removed before this candidate.
- Keep the researched lens description and focal value. Write the video aperture with the reference's F prefix; normalize only the canonical numeric readback alias. Apple documents both prefixed and unprefixed iris values, so this consistency change alone is not a proven root cause of the Photos heading.
- Keep encoded samples, codec, dimensions, frame rate, HDR and audio unchanged. Metadata editing cannot turn H.264 into HEVC or SDR into Dolby Vision.
- Preserve existing selected GPS write/removal behavior. No GPS or map-display guarantee follows from the screenshots.

## Qualification

Use synthetic MOV/MP4 regressions and AVFoundation's metadata reader, plus the existing sample/presentation preservation checks. Keep user media local and out of CI, Git and release packages. Advance build identity to 1.0.11+21 and bind the package to exact successful CI source.

Apple Photos camera-heading and friendly-lens presentation still require testing the new exported copy on a physical iPhone. Do not substitute passing source, CI or simulator results for that evidence.
