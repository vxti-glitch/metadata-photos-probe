# Metadata Editor UI redesign

Version 1.0.7, build 13. The owner authorized the complete previously planned redesign, retaining the Metadata Editor name, refined existing mark, blue accent and vxti attribution.

## Implemented flow

- Home has one media picker with Photos and Files choices. Multiple selections enter batch editing automatically. Settings opens from the gear; there is no bottom navigation.
- Selecting media prepares randomized supported metadata. A recognized device matches the researched phone profile; camera selection remains visible. Hardware values follow the selected profile and unsupported hardware is not invented.
- Manual editing is initially closed. It retains profiles, all supported fields and removal modes, ranges, dates, location controls, privacy removal, saved presets and recipes, and optional batch timestamp spacing. Manual controls wait for initial automatic preparation to finish.
- Review freezes a shared metadata plan and unique native-reserved IMG_#### names. Every applicable batch file receives the shared plan shaped to its format. Explicit Keep choices, unsupported fields and manually enabled timestamp spacing can differ by file.
- Results retain existing integrity and acknowledgment gates. Reopened local projects can export eligible saved copies without reprocessing. Unfinished batch recovery retries its frozen queue; a failed new attempt does not present an older copy as a new result.
- Settings contains focused destinations for appearance, local projects, presets, media/export, the Photos guide, diagnostics, app information, and Error Codes & Fixes. Ordinary support and website rows remain grouped with these destinations.
- System, Light and Dark appearance apply immediately and persist. Changing appearance preserves selection, draft, review plan, current operation and navigation state.
- Contact support opens the platform's mail handler using a fixed recipient and subject. It does not send mail, attach files or accept arbitrary bridge destinations.

## Evidence boundaries

Actual Flutter captures use synthetic sessions and substituted Windows fonts. They document implemented widgets, not physical iPhone behavior. Cloud Swift/native tests, simulator launch and the arm64 device archive must be reported separately from these captures. The unsigned IPA requires authorized signing. Default email-handler behavior, Photos/iCloud provider flows and physical installation remain device acceptance checks.
