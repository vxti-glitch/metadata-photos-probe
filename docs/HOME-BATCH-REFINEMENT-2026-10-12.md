# Home and batch refinement — 1.0.9 (15)

The Home header groups the existing logo, Metadata Editor name and by-vxti credit at the top left. A Settings sliders button remains available during loading and startup failure. A restrained blue/indigo gradient appears only on Home, with corresponding pale colors in light mode. The media picker and existing editing features remain available.

## Reproduced batch defect

A video-first automatic mixed batch generated date strings without image timezone fields. When the shared plan was shaped for each photo, those missing fields fell back to the photos' different original timezones. The automatic date family now freezes its generated timezone once alongside the date plan. Explicit per-photo Keep timezone intent still retains original offsets. Review, back navigation and retries do not regenerate the plan.

Four new synthetic regression cases cover five PNG screenshots, video-first mixed files on recognized and unknown phones, and explicit Keep timezone intent. The five-PNG case already passed before the fix: all files received the same randomized exposure/date/profile patch, unique IMG filenames, and unchanged originals.

## Batch result presentation

Successful processing now says Copy created and separately reports Verification passed or Verification limited. Each copy's complete checks and limitations remain accessible in a collapsed Details row. The explicit acceptance requirement for incomplete verification, failed-copy export blocks and retry behavior remain in place.

## Evidence boundaries

The user's actual batch exports were unavailable. Synthetic checks establish application behavior; they do not independently establish the ISO/date values in that earlier batch. The earlier Photos-imported MOV preservation failure has not been reproduced with the private source on an Apple device and is not claimed fixed by this release. Media writing and integrity requirements are unchanged. Widget captures use synthetic data and Windows font substitution; they are not physical iPhone screenshots. An unsigned IPA requires signing before installation.
