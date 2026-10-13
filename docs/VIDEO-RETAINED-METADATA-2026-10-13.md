# Video retained-metadata qualification

The owner reported Test 21 FAIL on 1.0.11+17 while processing downloaded videos. Expanded device diagnostics identify `retained_metadata` (Unchanged metadata), not compressed samples, audio, duration or requested-field readback. Private attachments were inspected locally only. They are QuickTime-brand H.264/AAC MOV with valid supported chunk mappings; exact equivalence to the originally downloaded MP4s is not established.

## Narrow correction

The previous video inventory fallback used `String(describing: item.key)` when Apple supplied no metadata identifier. Because `key` is optional, this can store a wrapper description instead of the actual metadata key, defeating selected-field alias matching. The corrected inventory uses Apple's public key/keyspace identifier API and an unwrapped, namespace-qualified fallback. Values without usable identity are refused instead of silently omitted.

The correction is a confirmed key-handling defect; it is not yet a confirmed resolution of the reported handset failure. Tests cover selected-key identity, unknown namespace separation and malformed/unkeyed input. Retained-metadata comparison remains strict, and compressed media/track/timing checks remain unchanged.

Additional failed-check categories use only a fixed vocabulary of known fields and generic unknown-key classes. No metadata values, arbitrary raw key strings, filenames or GPS values are sent through diagnostics. The aggregate Unchanged metadata check remains a failure when any retained value differs.

## Candidate and acceptance

Keep app version 1.0.11; increment build to 18 to distinguish the corrected binary from installed build 17. Preserve the verified build 17 package. Require exact-source Swift/native/Flutter and packaging gates plus independent review before handoff. The final artifact report records actual build results and hashes.

The owner handles authorized sideload signing. No signed installation or physical success is claimed here. Retest both reported videos, single-file and batch, from Photos and Files when available; inspect new failure categories if processing still fails. A successful file must retain original format, requested values, unrelated metadata and audio/video presentation. Actual HDR and Photos/iCloud display/attribution remain separate physical acceptance gates. Public launch remains NO-GO until those required results and owner approval exist.
