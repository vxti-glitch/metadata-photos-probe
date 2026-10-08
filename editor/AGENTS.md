# Flutter editor

User-approved architecture: Flutter interface, separate native Swift engine, iPhone-first local processing. The owner accepted explicit Files -> Safari/iCloud Photos -> sync as the no-label workflow. Do not imply native Photos saving suppresses attribution. Do not automate undocumented iCloud endpoints or capture account credentials.

The first deliverable is the single-file editor foundation, not a mockup: real Photos/Files import, source inspection, qualified camera-field edits, native integrity/readback, Files export, bounded session recovery and cleanup. The broader field/preset/randomization/removal/bulk milestones remain in docs/MAIN-APP-MILESTONES.md and are not silently dropped or advertised prematurely.

Keep canonical Swift processing in ../../Sources/ProbeCore and link it via a local Swift package. Swift owns media and opaque session identifiers. Never pass full media through Flutter channels or accept arbitrary Dart-supplied paths. Preserve original/provider media. Native independently enforces output-token and export gates. Unqualified quality stays incomplete; mismatches block export. Thumbnails are separate display derivatives, never processing outputs.

Respect editor/docs/BRIDGE-CONTRACT.md. Separate UI/native ownership, serialization bounds, operation tokens and callback cancellation. Treat recovery manifests as untrusted; validate IDs, sandbox paths and counts. Use synthetic CI inputs only; user media/GPS, signing inputs and local reports stay out of source and CI.

Run Flutter analysis/tests, Swift engine and native bridge tests and a real cloud iOS build before packaging. Independent code review and final verification are required. Signing, simulator, packaged IPA and physical-device behavior are separate results. Do not overwrite the existing probe or its evidence.
