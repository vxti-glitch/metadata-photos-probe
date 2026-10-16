# Location picker placement — 1.0.10 (16)

The main editing card now presents Your phone, Camera, and Location together. Location opens the existing map picker. After a point is selected, the row shows its latitude and longitude. The picked point is an explicit Set override for both coordinates and follows the existing per-format and batch patch rules. Formats without both GPS fields do not show the row. Manual coordinate fields remain in Manual editing. The older compact editing path retains its map control inside the Location group.

This change concerns where the picker appears. The map implementation, media writer, verification rules, original-file behavior and export gates are unchanged. Two focused widget checks cover a single image and a two-image batch. The visual captures use synthetic fixtures and Windows fonts; device behavior needs separate acceptance.
