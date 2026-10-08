# Flutter / Swift media contract, version 1

Channel: `com.vxtiglitch.metadataeditor/media_v1`, StandardMethodCodec. Swift owns media and opaque session identifiers; Dart never sends paths or media bytes. Return JSON-compatible maps/lists/primitives. Only thumbnail paths created inside the app's cache may cross for display. Native output remains immutable for a frozen processing identifier. No automatic media upload or Photos write is included.

- `capabilities`: `{protocolVersion:1, formats:[jpeg,heic,mp4,mov], editableFields:[make,model,lens], videoStatus:provisional}`. Lens is image-only; HEIC changed camera strings are ASCII-only.
- `listSessions`: list of Session maps, most recent first, from a bounded versioned atomic local manifest. Recover original/output references, not active OS operations.
- `importFiles`, `importPhotos`: present native single-file pickers and return Session or null on cancellation. Photos retrieves the authorized original and refuses Live Photos. Files uses coordinated security-scoped copying. Sources are immutable. Name/origin and any original-versus-current limitation are visible.
- `process`: `{sessionId, patch:{make,model,lens:null|string}}` -> updated Session. Empty lens means preserve; otherwise reject video lens requests. Clear the active prior output before starting; retain prior history safely. Core exact camera readback and independent comparisons are mandatory.
- `exportFiles`: `{sessionId, processingId, acknowledgeIncomplete:bool}` -> `{completed:bool}`. Swift verifies the frozen output ID, existence, no mismatch and explicit incomplete acknowledgment before presenting a copy exporter. Completion means Files only; it cannot confirm Safari upload or Photos attribution.
- `cancel`: requests cancellation of the one active operation; importing/processing/export may remain busy until its real native completion. Do not accept replacement work before then.
- `deleteSession`: `{sessionId}` -> null. Delete only app-owned paths when no operation is active; never change provider originals or Photos assets.
- `clearSessions`: null -> null, same constraints.
- `openICloud`: null -> null, opens fixed public `https://www.icloud.com/photos/` in the system browser. No credential capture or undocumented upload endpoint.

Session map: `{id, displayName, origin, createdAt, inspection, details?, notes:[string], previewPath?:string, processing?:Processing}`. Inspection is the canonical MediaInspection JSON (`kind,byteCount,metadata,structure,location?,notes`). `details` contains known readable metadata fields only, no opaque/binary values. Camera metadata comes from native inspection, not guessed filenames or library provenance.

Processing map: `{id, createdAt, patch, outputInspection, integrity}`. Integrity is canonical JSON (`status:verified|incomplete|mismatch, checks:[{name,status,detail}], limitations:[string]`). Return UUID identifiers and ISO-8601 timestamps. Absolute source/output paths remain native-only. Errors use FlutterError codes `busy`, `canceled`, `permission`, `unsupported`, `invalid_argument`, `not_found`, `storage`, `processing`, with helpful messages and no actual media/path logging.

UI state clears acknowledgments on output/session changes. Native independently validates the processing token and gate; Dart test doubles cannot replace these safeguards. Background media operations must not block Flutter's main thread. Session recovery and cleanup are bounded and sandbox-confined. User media/GPS stay local and excluded from CI.
