# Additional file-details warnings — owner-approved editor policy

Version 1.0.11 build 19 implements the owner's approval to allow a copy when only the retained-metadata comparison fails. This supersedes the editor's previous rule that every metadata comparison mismatch blocks output. It does not relax media preservation or requested-edit checks. The canonical diagnostic probe and default Swift engine policy remain strict.

## Consumer wording and behavior

The primary warning is **Some other file details may have changed.** The copy remains available for Export to Files or sharing. It is a warning result, never labeled fully verified. Single-file and batch results show the warning; optional Details retain the underlying evidence. The error guide replaces the old consumer label Unchanged metadata with the new wording.

Warnings alone do not add an acknowledgment requirement. Existing incomplete media checks still require their existing acknowledgment before export. Sources stay immutable; no format conversion, re-encoding or dropped tracks are introduced.

## Exact policy scope

Only the exact `retained embedded metadata` check and its closed, code-owned supplemental diagnostic names may become `warning`. Unknown failure names, container/media sample/timing/inventory failures, requested-value/removal readback failures, independent location comparison and image-property failures remain blocking. A requested GPS removal that cannot be verified must not become a warning.

Integrity reports support explicit warning status and warning checks. Reports with unchecked media or limitations remain incomplete, even when they also have file-details warnings. Arbitrary warning names, contradictory reports and empty evidence are not accepted as verified outputs. Export and recovered-project requalification apply the same editor policy, recheck source/output hashes and retain the processing-token gate. Warning results are not silently published by automatic Files saving.

## Accepted limitation

The owner accepts that other embedded file details may be added, removed or changed when this warning appears. The warning does not prove those differences are harmless or certify actual Photos display, HDR or application attribution. The previously reported build 18 failure is not claimed repaired at its root; build 19 intentionally changes the treatment of that specific check.

## Tests and device acceptance

Regressions cover strict-default rejection, exact warning conversion, simultaneous hard failure, unknown failure/warning rejection, warning plus incomplete acknowledgment, requested edits/GPS failures, source immutability, single/batch export/share and recovered-project qualification. Exact native/cloud results and hashes belong in the final build 19 artifact report.

Retest the failing videos on installed build 19. A file-details warning should leave a copy available; any remaining preservation failure should still block it. Inspect saved requested values, playback/audio/synchronization and the original source. Run the existing physical checklist, including actual HDR and Photos/iCloud metadata display/provenance. Public launch remains subject to physical qualification and owner approval.

Preserve builds 17 and 18. New warning reports are a forward schema addition; older builds may not read those reports. Export required local work and back up disposable test sources before a downgrade. No automatic Photos rollback or signed installation is claimed.
