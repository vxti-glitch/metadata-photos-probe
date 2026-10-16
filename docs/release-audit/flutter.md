# Flutter editor and native picker audit (13 October 2026)

## Scope

Read the editor controller, native method bridge, fake bridge, main metadata form, Settings, error guide, batch result/export paths, and the iOS location picker. Checked the batch processing and retry state transitions, selected output IDs, cancellation, appearance forwarding, and map/manual location controls. This is a source and automated-test audit; it does not establish physical-device behavior.

## Confirmed issues and corrections

| Issue | Correction | Evidence |
| --- | --- | --- |
| The map picker could apply its default map center without a selected pin, potentially writing an unintended coordinate. | Apply is disabled until a valid existing coordinate or a deliberate tap/long-press pin exists. Invalid coordinates are ignored. | New `RunnerTests` cover empty, valid existing, invalid existing, and invalid new pins. Native tests require macOS execution. |
| Forced Light/Dark appearance in Flutter did not reach the native MapKit sheet. | The controller forwards a bounded System/Light/Dark value; the bridge validates it; the navigation controller and picker use the selected interface style and adaptive UIKit colors. | Flutter appearance/bridge tests passed; native appearance test added for macOS. |
| Opaque video location failures did not explain the available safe choice. | The error guidance now directs the user to set altitude explicitly with map coordinates or remove latitude, longitude, and altitude together. Timed metadata track refusal is also stated directly. | Native error-message regression test added for macOS. |
| Batch export, single share, and batch share interpreted a missing or non-boolean native `completed` field as user cancellation. | Each method now requires a boolean, matching single-file export; malformed responses raise `FormatException`. | Parameterized bridge test covers absent, string, integer and null responses, plus valid false/true, for all three methods. |

## Checks and limitations

- On the frozen 1.0.11+17 working tree, `flutter analyze` found no issues, Dart formatting checked 31 files with zero changes, and the full Flutter suite passed 226/226. Logs: `build/audit/final-release/analysis.log`, `format.log`, and `full-tests.log`. The focused bridge suite also passed 19/19.
- `RunnerTests.swift` contains 50 test methods, including four new location/appearance/message tests. They could not run on Windows; the macOS CI/iOS simulator gate must execute them and compile the native code.
- No further confirmed high-priority controller, batch retry, Settings, or export state bug was found in this pass. Device Photos imports, actual MP4/MOV/PNG preservation, map interaction, Files export, iCloud upload, and Apple Photos display remain separate acceptance checks.
- The test and analysis results apply only to the working tree at the time run. A source SHA and fresh macOS CI run are necessary for release claims.
