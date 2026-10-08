# Flutter editor

User-approved architecture: Flutter interface, separate native Swift engine, iPhone-first local processing. The owner accepted explicit Files -> Safari/iCloud Photos -> sync as the no-label workflow. Do not imply native Photos saving suppresses attribution. Do not automate undocumented iCloud endpoints or capture account credentials.

The user has confirmed the full script-derived scope: metadata fields beyond make/model/lens, selected removal, researched Brand/Model/Camera profiles, configurable randomization, saved presets, bulk processing, IMG_#### output filenames and a minimal main flow. Implement real native operations and durable state for these features. Do not advertise a writer or quality guarantee before validation; hide technical reports in optional Details while retaining automatic export gates.

Keep canonical Swift processing in repository-root Sources/ProbeCore (../Sources/ProbeCore from editor/, or ../../Sources/ProbeCore from editor/ios) and link it via a local Swift package. Swift owns media and opaque session identifiers. Never pass full media through Flutter channels or accept arbitrary Dart-supplied paths. Preserve original/provider media. Native independently enforces output-token and export gates. Unqualified quality stays incomplete; mismatches block export. Thumbnails are separate display derivatives, never processing outputs.

Respect editor/docs/BRIDGE-CONTRACT.md. Separate UI/native ownership, serialization bounds, operation tokens and callback cancellation. Treat recovery manifests as untrusted; validate IDs, sandbox paths and counts. Use synthetic CI inputs only; user media/GPS, signing inputs and local reports stay out of source and CI.

Run Flutter analysis/tests, Swift engine and native bridge tests and a real cloud iOS build before packaging. Independent code review and final verification are required. Signing, simulator, packaged IPA and physical-device behavior are separate results. Do not overwrite the existing probe or its evidence.
