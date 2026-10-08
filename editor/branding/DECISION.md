# Product name and visual identity

Updated October 8, 2026. The user requested independent branding, authorized competitor/name research, then clarified that a straightforward name would make the Zlarp listing easier to understand. The final implementation uses **Metadata Editor**, subtitle **Photo & Video Metadata**, and the short line **Your media. Your metadata.** Zlarp remains project/distribution context. The earlier coined-name exploration is superseded.

## Research that informed the choice

| Comparable app | Observed naming approach |
| --- | --- |
| [Metapho](https://zininworks.com/metapho) | Coined product name plus a descriptive EXIF/metadata subtitle; photos and videos. |
| [Exif Metadata](https://apps.apple.com/us/app/exif-metadata/id1455197364) | Direct category name that states the purpose. |
| [ViewExif](https://apps.apple.com/us/app/viewexif/id945320815) | Short action/category name. |
| [EXIF Viewer by Fluntro](https://apps.apple.com/us/app/exif-viewer-by-fluntro/id944118456) | Descriptive tool name with an independent developer identity. |
| [Photo Investigator](https://apps.apple.com/us/app/photo-investigator-gps-exif/id571574618) | Descriptive purpose name. |

These are primary developer/App Store sources inspected during the naming research. The judgment is that a descriptive name best fits the user's final listing priority. The photo/video subtitle avoids presenting this broader media tool as an EXIF-only photo viewer. This research does not expand the alpha's implemented feature coverage.

Coined candidates were screened with exact broad searches and store/software searches. Several attractive names already had related uses: [Frameta](https://frameta.vercel.app/) is an EXIF-watermark tool, [FrameQuill](https://www.linkedin.com/company/framequill-agency) a media agency, [Framekeep](https://framekeep.app/) a screen-recording product, and [Taglume](https://taglume.com/) a data platform. Framevell had no obvious indexed same-name software result in our checks, but the user subsequently preferred straightforward naming. No trademark, domain reservation, exclusive rights or App Store name reservation is claimed for any candidate. No domain or external brand account was purchased or created.

## Applied identity

- Display/product name: **Metadata Editor**.
- Subtitle: **Photo & Video Metadata**; compact header qualifier **Photo & Video**.
- Charcoal background `#0E1115`, raised surface `#191E25`, teal accent `#84E4C7`, light text `#E7EDF4`.
- Original symbol: four media-frame corners with three metadata rows. It has no customer initial, camera-aperture copy or claim of authenticated provenance.
- `mark.svg` is the editable master. `render_icons.py` creates the committed opaque iOS icon and launch assets from that original geometry; it is a development utility requiring Pillow, not an application dependency.
- Flutter's neutral mark uses the same 32-unit geometry. User-facing brand strings and the versioned channel are centralized in `lib/app_brand.dart`.
- Independent package: `metadata_editor`; iOS bundle: `com.vxtiglitch.metadataeditor`; channel: `com.vxtiglitch.metadataeditor/media_v1`.

Copy describes real actions and qualified quality results. It does not promise universal losslessness, automatic uploads, removal of Photos library provenance, or full roadmap features in this first milestone.
