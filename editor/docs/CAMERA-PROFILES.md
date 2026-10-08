# Camera profiles

The catalog contains 42 device profiles and 146 camera choices across Apple, Samsung and Google. Each links to manufacturer specifications. This is an extensible catalog, not every historical phone. `scripts/editor-camera-profiles.py` regenerates the checked-in JSON.

Aperture and available equivalent focal lengths use published specifications. Equivalent and physical focal lengths are distinct. Unknown physical focal lengths are omitted. Descriptive lens labels identify the selected camera without claiming authentic capture identifiers.

The three rear iPhone 15 Pro Max lens literals, physical focal lengths and four software candidates reproduce the supplied `spoof_exif.py`, identified as `user-script`. They are not independently verified manufacturer firmware metadata.

ISO 40–1000 and shutter choices are configurable scenario defaults from the script, not hardware limits or proof of a real photographed scene. Pattern metering is EXIF 5; Off, did not fire is Flash 16, per the maintained [ExifTool EXIF definitions](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/Exif.pm).

Apply profile and camera `clearFields` before explicit overrides. This prevents carrying another phone's unknown physical focal length or software into a new profile; unrelated exposure/location/dates are preserved unless the user changes them. Camera field provenance is visible in optional Details.

Samsung product names do not claim regional SM capture identifiers. SE generation labels identify selectable profiles rather than asserting exact EXIF spelling. Photos display and uploaded-original integrity still require physical-device checks. Actual dimensions, codec, HDR, frame rate, duration and compressed media describe the source.
