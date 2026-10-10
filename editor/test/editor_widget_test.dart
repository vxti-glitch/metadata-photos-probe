import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_form.dart';
import 'package:metadata_editor/metadata_patch.dart';
import 'package:metadata_editor/metadata_dates.dart';

import 'fake_media_bridge.dart';

void main() {
  Future<EditorController> launch(
    WidgetTester tester,
    FakeMediaBridge bridge,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(loadCameraProfiles);
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MetadataEditorApp(controller: controller));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> setField(WidgetTester tester, String field, String value) async {
    final mode = find.byKey(Key('${field}Mode'));
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    final input = find.byKey(Key(field));
    await tester.ensureVisible(input);
    await tester.pumpAndSettle();
    await tester.enterText(input, value);
  }

  Future<void> switchToEditTab(WidgetTester tester) async {
    final tab = find.text('Edit').first;
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  testWidgets('automatic capture dates work without a camera preset', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    await tap(tester, 'importFiles');
    await tap(tester, 'process');
    final patch = bridge.sessions.single.processing!.metadataPatch!;
    expect(patch.values['dateTimeOriginal'], isNotNull);
    expect(patch.values['dateTimeOriginal'], patch.values['createDate']);
    expect(patch.values['offsetTimeOriginal'], isNotNull);
    expect(patch.values.containsKey('make'), isFalse);
  });

  testWidgets('manual date picker works without choosing a camera preset', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    await tap(tester, 'importFiles');
    await tap(tester, 'automaticDates');
    await tap(tester, 'setCaptureDate');
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tap(tester, 'process');
    final patch = bridge.sessions.single.processing!.metadataPatch!;
    expect(patch.values['dateTimeOriginal'], patch.values['modifyDate']);
    expect(patch.values['offsetTimeDigitized'], isNotNull);
    expect(patch.values.containsKey('model'), isFalse);
  });

  testWidgets(
    'HEIC manual editing, mandatory limitation gate, Files export and optional details',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      await tap(tester, 'importPhotos');
      await switchToEditTab(tester);
      await setField(tester, 'make', 'Apple');
      await setField(tester, 'model', 'Controlled Phone');
      await tap(tester, 'process');
      expect(find.text('Review the processed copy'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('exportFiles')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'acknowledge');
      await tap(tester, 'exportFiles');
      expect(bridge.exports, 1);
      await tap(tester, 'openICloud');
      expect(bridge.opens, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed preservation blocks export without offering acknowledgment',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..importResult = fixture(kind: MediaKind.mov)
        ..nextStatus = IntegrityStatus.mismatch;
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      await switchToEditTab(tester);
      await setField(tester, 'make', 'Apple');
      await tap(tester, 'process');
      expect(find.textContaining('Export blocked.'), findsWidgets);
      expect(find.byKey(const Key('acknowledge')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('exportFiles')))
            .onPressed,
        isNull,
      );
      expect(bridge.exports, 0);
    },
  );

  testWidgets(
    'Brand and model selection automatically fills a coherent profile',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      final brand = find.byKey(const Key('profileBrand'));
      await tester.ensureVisible(brand);
      await tester.pumpAndSettle();
      await tester.tap(brand);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apple').last);
      await tester.pumpAndSettle();
      final model = find.byKey(const ValueKey('model-Apple'));
      await tester.ensureVisible(model);
      await tester.pumpAndSettle();
      await tester.tap(model);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'iPhone 15 Pro Max');
      await tester.pumpAndSettle();
      await tester.tap(find.text('iPhone 15 Pro Max').last);
      await tester.pumpAndSettle();
      await tap(tester, 'process');
      final plan = bridge.sessions.single.processing!.metadataPatch!;
      expect(plan.values['make'], 'Apple');
      expect(plan.values['model'], 'iPhone 15 Pro Max');
      expect(plan.values['fNumber'], 1.78);
      expect(plan.values['iso'], isA<num>());
      expect(plan.values['lensModel'], contains('6.765mm'));
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> chooseProfile(WidgetTester tester) async {
    final brand = find.byKey(const Key('profileBrand'));
    await tester.ensureVisible(brand);
    await tester.pumpAndSettle();
    await tester.tap(brand);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple').last);
    await tester.pumpAndSettle();
    final model = find.byKey(const ValueKey('model-Apple'));
    await tester.ensureVisible(model);
    await tester.pumpAndSettle();
    await tester.tap(model);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'iPhone 15 Pro Max');
    await tester.pumpAndSettle();
    await tester.tap(find.text('iPhone 15 Pro Max').last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'bulk preserves explicit ISO equal to the displayed profile value',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId)];
      final controller = await launch(tester, bridge);
      for (final source in controller.sessions) {
        controller.toggleBatch(source, true);
      }
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scrollController,
              child: MetadataForm(
                controller: controller,
                session: controller.sessions.first,
                batch: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await chooseProfile(tester);
      await switchToEditTab(tester);
      await tester.ensureVisible(find.text('Exposure').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exposure').first);
      await tester.pumpAndSettle();
      final isoInput = find.byKey(const Key('iso'));
      final displayedISO = tester.widget<TextField>(isoInput).controller!.text;
      await tester.ensureVisible(isoInput);
      await tester.pumpAndSettle();
      await tester.enterText(isoInput, '');
      await tester.enterText(isoInput, displayedISO);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap(tester, 'process');
      expect(bridge.processes, 2);
      for (final source in bridge.sessions) {
        expect(
          source.processing!.metadataPatch!.values['iso'],
          num.parse(displayedISO),
        );
      }
    },
  );

  testWidgets('mixed recipe keeps movie-only overrides with an image first', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..sessions = [fixture(), fixture(id: nextOutputId, kind: MediaKind.mov)]
      ..fieldsByFormat = {
        'heic': ['make', 'model'],
        'mov': ['make', 'model', 'movieCreateDate'],
      };
    final controller = await launch(tester, bridge);
    final profile = (await loadCameraProfiles()).firstWhere(
      (p) => p.model == 'iPhone 15 Pro Max',
    );
    const fixedDate = '2026-04-05T06:07:08Z';
    controller.presets = [
      SavedPreset(
        sourceId,
        'Mixed recipe',
        MetadataPatch(values: {'make': 'Apple'}),
        recipe: ProfileRecipe(
          profile.id,
          profile.cameras.first.id,
          const RandomizationSettings(),
          overrides: MetadataPatch(values: {'movieCreateDate': fixedDate}),
        ),
      ),
    ];
    for (final source in controller.sessions) {
      controller.toggleBatch(source, true);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MetadataForm(
              controller: controller,
              session: controller.sessions.first,
              batch: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mixed recipe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mixed recipe'));
    await tester.pumpAndSettle();
    await tap(tester, 'process');
    expect(bridge.processes, 2);
    final image = bridge.sessions.firstWhere((s) => s.inspection.kind.isImage);
    final movie = bridge.sessions.firstWhere((s) => !s.inspection.kind.isImage);
    expect(
      image.processing!.metadataPatch!.values.containsKey('movieCreateDate'),
      isFalse,
    );
    expect(
      movie.processing!.metadataPatch!.values['movieCreateDate'],
      fixedDate,
    );
    expect(tester.takeException(), isNull);
  });

  for (final imageFirst in [true, false]) {
    for (final withProfile in [true, false]) {
      testWidgets(
        'mixed calendar honors per-format dates imageFirst=$imageFirst profile=$withProfile',
        (tester) async {
          final photo = fixture(id: sourceId),
              movie = fixture(id: nextOutputId, kind: MediaKind.mov);
          final bridge = FakeMediaBridge()
            ..sessions = imageFirst ? [photo, movie] : [movie, photo]
            ..fieldsByFormat = {
              'heic': [
                'make',
                'model',
                ...sharedDateOffsets.keys,
                ...sharedDateOffsets.values,
              ],
              'mov': [
                'make',
                'model',
                ...sharedDateOffsets.keys,
                ...movieDateKeys,
              ],
            };
          final controller = await launch(tester, bridge);
          for (final source in controller.sessions) {
            controller.toggleBatch(source, true);
          }
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: MetadataForm(
                    controller: controller,
                    session: controller.sessions.first,
                    batch: true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (withProfile) await chooseProfile(tester);
          await tap(tester, 'automaticDates');
          await tap(tester, 'setCaptureDate');
          await tester.tap(find.text('OK').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('OK').last);
          await tester.pumpAndSettle();
          await tap(tester, 'process');
          expect(bridge.processes, 2);
          final imagePatch = bridge.sessions
              .firstWhere((s) => s.inspection.kind.isImage)
              .processing!
              .metadataPatch!;
          final videoPatch = bridge.sessions
              .firstWhere((s) => !s.inspection.kind.isImage)
              .processing!
              .metadataPatch!;
          final expected = datesForMedia(
            imagePatch,
            image: false,
          ).values['dateTimeOriginal'];
          for (final key in {...sharedDateOffsets.keys, ...movieDateKeys}) {
            expect(videoPatch.values[key], expected, reason: key);
          }
          expect(videoPatch.values.keys, isNot(contains('offsetTimeOriginal')));
          expect(imagePatch.values.keys, isNot(contains('movieCreateDate')));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'image-first recipe keeps the video header absent from its baseline',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId, kind: MediaKind.mov)]
        ..fieldsByFormat = {
          'heic': [
            'make',
            'model',
            ...sharedDateOffsets.keys,
            ...sharedDateOffsets.values,
          ],
          'mov': ['make', 'model', ...sharedDateOffsets.keys, ...movieDateKeys],
        };
      final controller = await launch(tester, bridge);
      final profile = (await loadCameraProfiles()).firstWhere(
        (p) => p.model == 'iPhone 15 Pro Max',
      );
      controller.presets = [
        SavedPreset(
          sourceId,
          'Keep track date',
          MetadataPatch(values: {'make': 'Apple'}),
          recipe: ProfileRecipe(
            profile.id,
            profile.cameras.first.id,
            const RandomizationSettings(),
            keepFields: {'trackCreateDate'},
          ),
        ),
      ];
      for (final source in controller.sessions) {
        controller.toggleBatch(source, true);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MetadataForm(
                controller: controller,
                session: controller.sessions.first,
                batch: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Keep track date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep track date'));
      await tester.pumpAndSettle();
      await tap(tester, 'process');
      expect(bridge.processes, 2);
      final movie = bridge.sessions
          .firstWhere((s) => !s.inspection.kind.isImage)
          .processing!
          .metadataPatch!;
      expect(movie.values.containsKey('trackCreateDate'), isFalse);
      expect(movie.removals.contains('trackCreateDate'), isFalse);
      expect(movie.values.containsKey('mediaCreateDate'), isTrue);
    },
  );

  testWidgets(
    'video-first recipe keeps each photo zone for its fixed ISO instant',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [
          fixture(kind: MediaKind.mov),
          fixture(
            id: nextOutputId,
            additionalMetadata: {'offsetTimeOriginal': '+02:00'},
          ),
          fixture(
            id: outputId,
            additionalMetadata: {'offsetTimeOriginal': '-04:00'},
          ),
        ]
        ..fieldsByFormat = {
          'heic': [
            'make',
            'model',
            ...sharedDateOffsets.keys,
            ...sharedDateOffsets.values,
          ],
          'mov': ['make', 'model', ...sharedDateOffsets.keys, ...movieDateKeys],
        };
      final controller = await launch(tester, bridge);
      final profile = (await loadCameraProfiles()).firstWhere(
        (p) => p.model == 'iPhone 15 Pro Max',
      );
      controller.presets = [
        SavedPreset(
          sourceId,
          'Keep photo zones',
          MetadataPatch(values: {'make': 'Apple'}),
          recipe: ProfileRecipe(
            profile.id,
            profile.cameras.first.id,
            const RandomizationSettings(),
            overrides: MetadataPatch(
              values: {'dateTimeOriginal': '2026-04-05T10:00:00Z'},
            ),
            keepFields: {'offsetTimeOriginal'},
          ),
        ),
      ];
      for (final source in controller.sessions) {
        controller.toggleBatch(source, true);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MetadataForm(
                controller: controller,
                session: controller.sessions.first,
                batch: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Keep photo zones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep photo zones'));
      await tester.pumpAndSettle();
      await tap(tester, 'process');
      expect(bridge.processes, 3);
      for (final photo in bridge.sessions.where(
        (s) => s.inspection.kind.isImage,
      )) {
        final patch = photo.processing!.metadataPatch!;
        expect(patch.values.containsKey('offsetTimeOriginal'), isFalse);
        final instant = datesForMedia(
          patch,
          image: false,
          keptOffsets: photo.inspection.metadata,
        );
        expect(instant.values['dateTimeOriginal'], '2026-04-05T10:00:00.000Z');
      }
    },
  );

  for (final withProfile in [true, false]) {
    testWidgets(
      'single automatic date keeps its instant with retained zone profile=$withProfile',
      (tester) async {
        final bridge = FakeMediaBridge()
          ..sessions = [
            fixture(additionalMetadata: {'offsetTimeOriginal': '-05:00'}),
          ]
          ..fieldsByFormat = {
            'heic': [
              'make',
              'model',
              ...sharedDateOffsets.keys,
              ...sharedDateOffsets.values,
            ],
          };
        final controller = await launch(tester, bridge);
        controller.select(controller.sessions.first);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.first,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = DateTime.now().toUtc();
        final config = find.text('Randomization settings');
        await tester.ensureVisible(config);
        await tester.pumpAndSettle();
        await tester.tap(config);
        await tester.pumpAndSettle();
        final days = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == 'Within the past days',
        );
        await tester.ensureVisible(days);
        await tester.pumpAndSettle();
        await tester.enterText(days, '0');
        await tester.tap(find.text('Use settings'));
        await tester.pumpAndSettle();
        if (withProfile) await chooseProfile(tester);
        await switchToEditTab(tester);
        await tester.ensureVisible(find.text('Dates').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dates').first);
        await tester.pumpAndSettle();
        await setField(tester, 'offsetTimeOriginal', '-05:00');
        final mode = find.byKey(const Key('offsetTimeOriginalMode'));
        await tester.ensureVisible(mode);
        await tester.pumpAndSettle();
        await tester.tap(mode);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep').last);
        await tester.pumpAndSettle();
        await tap(tester, 'process');
        expect(bridge.processes, 1);
        final patch = bridge.sessions.single.processing!.metadataPatch!;
        expect(patch.values.containsKey('offsetTimeOriginal'), isFalse);
        final stamp =
            datesForMedia(
                  patch,
                  image: false,
                  keptOffsets: bridge.sessions.single.inspection.metadata,
                ).values['dateTimeOriginal']
                as String;
        final instant = DateTime.parse(stamp);
        expect(
          instant.isBefore(before.subtract(const Duration(seconds: 2))),
          isFalse,
        );
        expect(instant.isAfter(DateTime.now().toUtc()), isFalse);
      },
    );
  }

  testWidgets(
    'save preset completes its dialog transition and persists the recipe',
    (tester) async {
      final bridge = FakeMediaBridge();
      final controller = await launch(tester, bridge);
      await tap(tester, 'importFiles');
      await chooseProfile(tester);
      final save = find.text('Save current edits');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Name',
      );
      await tester.enterText(name, 'Studio');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(controller.presets.single.name, 'Studio');
      expect(controller.presets.single.recipe, isNotNull);
      expect((bridge.editorState['presets'] as List).length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in [MediaKind.heic, MediaKind.mov]) {
    testWidgets(
      'saved date recipe adapts a single ${kind.name} across formats',
      (tester) async {
        final bridge = FakeMediaBridge()
          ..sessions = [fixture(kind: kind)]
          ..fieldsByFormat = {
            'heic': [
              'make',
              'model',
              ...sharedDateOffsets.keys,
              ...sharedDateOffsets.values,
            ],
            'mov': [
              'make',
              'model',
              ...sharedDateOffsets.keys,
              ...movieDateKeys,
            ],
          };
        final controller = await launch(tester, bridge);
        final profile = (await loadCameraProfiles()).firstWhere(
          (p) => p.model == 'iPhone 15 Pro Max',
        );
        final datePatch = captureDatePatch(
          DateTime.utc(2026, 4, 5, 6, 7, 8),
          image: !kind.isImage,
        );
        controller.select(controller.sessions.first);
        controller.presets = [
          SavedPreset(
            sourceId,
            'Cross format dates',
            datePatch,
            recipe: ProfileRecipe(
              profile.id,
              profile.cameras.first.id,
              const RandomizationSettings(),
              overrides: datePatch,
            ),
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.first,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Cross format dates'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cross format dates'));
        await tester.pumpAndSettle();
        await tap(tester, 'process');
        expect(bridge.processes, 1);
        final output = bridge.sessions.single.processing!.metadataPatch!;
        final instant = datesForMedia(output, image: false);
        for (final key in {...sharedDateOffsets.keys, ...movieDateKeys}) {
          expect(instant.values[key], '2026-04-05T06:07:08.000Z', reason: key);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'turning automatic dates off after applying profile removes random date writes',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      await chooseProfile(tester);
      await tap(tester, 'automaticDates');
      await tap(tester, 'process');
      final patch = bridge.sessions.single.processing!.metadataPatch!;
      expect(
        patch.values.keys.any(
          (k) => k.toLowerCase().contains('date') || k.startsWith('offsetTime'),
        ),
        isFalse,
      );
      expect(
        patch.removals.any((k) => k.toLowerCase().contains('date')),
        isFalse,
      );
    },
  );
  testWidgets('automatic dates off retains explicitly entered capture date', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    await tap(tester, 'importFiles');
    await chooseProfile(tester);
    await switchToEditTab(tester);
    final dates = find.text('Dates');
    await tester.ensureVisible(dates);
    await tester.pumpAndSettle();
    await tester.tap(dates);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('dateTimeOriginal'));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, '2024:03:05 10:15:00');
    final checkbox = find.byKey(const Key('automaticDates')).first;
    await tester.ensureVisible(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    await tap(tester, 'process');
    final patch = bridge.sessions.single.processing!.metadataPatch!;
    expect(patch.values['dateTimeOriginal'], '2024:03:05 10:15:00');
    expect(patch.values.containsKey('createDate'), isFalse);
  });
  testWidgets(
    'manual date and time picker changes capture metadata and Details shows processed readback',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      await chooseProfile(tester);
      await tap(tester, 'automaticDates');
      await tap(tester, 'setCaptureDate');
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK').last);
      await tester.pumpAndSettle();
      await tap(tester, 'process');
      final patch = bridge.sessions.single.processing!.metadataPatch!;
      expect(patch.values['dateTimeOriginal'], isNotNull);
      expect(patch.values['dateTimeOriginal'], patch.values['createDate']);
      await tester.ensureVisible(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('Original metadata'), findsOneWidget);
      expect(find.text('Processed metadata read back'), findsOneWidget);
      expect(find.text('Read back · iso'), findsOneWidget);
      expect(find.text('Read back · dateTimeOriginal'), findsOneWidget);
      expect(find.text('Camera profile evidence'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('permission error is visible and import remains retryable', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..importError = PlatformException(
        code: 'permission',
        message: 'Allow Photos access in Settings.',
      );
    await launch(tester, bridge);
    await tap(tester, 'importPhotos');
    expect(find.text('Allow Photos access in Settings.'), findsOneWidget);
    bridge.importError = null;
    await tap(tester, 'importPhotos');
    expect(find.text('controlled.heic'), findsOneWidget);
  });
  testWidgets(
    'local history removal has confirmation and calls only opaque session deletion',
    (tester) async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      await launch(tester, bridge);
      await tester.ensureVisible(find.byTooltip('Remove controlled.heic'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove controlled.heic'));
      await tester.pumpAndSettle();
      expect(find.text('Remove local project?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(bridge.deletedIds, isEmpty);
      await tester.tap(find.byTooltip('Remove controlled.heic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(bridge.deletedIds, [sourceId]);
      expect(find.text('No projects yet'), findsOneWidget);
    },
  );
  testWidgets('phone layout supports increased text size without overflow', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    expect(tester.takeException(), isNull);
    await tap(tester, 'importFiles');
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown menu constraints and model search sheet', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    await tap(tester, 'importFiles');
    final brand = find.byKey(const Key('profileBrand'));
    await tester.ensureVisible(brand);
    expect(brand, findsOneWidget);

    await tester.tap(brand);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple').last);
    await tester.pumpAndSettle();

    final model = find.byKey(const ValueKey('model-Apple'));
    expect(model, findsOneWidget);

    final searchIcon = find.byTooltip('Search models');
    expect(searchIcon, findsOneWidget);
    await tester.tap(searchIcon);
    await tester.pumpAndSettle();

    expect(find.text('Select Camera Model'), findsOneWidget);
    final searchInput = find.byType(TextField);
    expect(searchInput, findsOneWidget);
    await tester.enterText(searchInput, 'iPhone 15');
    await tester.pumpAndSettle();

    final modelTile = find.text('iPhone 15 Pro Max');
    expect(modelTile, findsOneWidget);
    await tester.tap(modelTile);
    await tester.pumpAndSettle();

    expect(find.text('Select Camera Model'), findsNothing);
    expect(find.text('iPhone 15 Pro Max'), findsOneWidget);
  });

  testWidgets('camera picker bottom sheet opens and updates selected camera', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    await tap(tester, 'importFiles');
    await chooseProfile(tester);

    final cameraSelector = find.byKey(
      const ValueKey('camera-apple-iphone-15-pro-max-main'),
    );
    await tester.ensureVisible(cameraSelector);
    expect(cameraSelector, findsOneWidget);
    expect(find.text('Main Camera'), findsOneWidget);

    await tester.tap(cameraSelector);
    await tester.pumpAndSettle();

    expect(find.text('Select Camera'), findsOneWidget);
    expect(find.text('iPhone 15 Pro Max'), findsWidgets);
    expect(find.text('Ultra Wide'), findsOneWidget);

    await tester.tap(find.text('Ultra Wide').last);
    await tester.pumpAndSettle();

    expect(find.text('Select Camera'), findsNothing);
    expect(find.text('Ultra Wide'), findsOneWidget);

    await tap(tester, 'process');
    final patch = bridge.sessions.single.processing!.metadataPatch!;
    expect(patch.values['fNumber'], 2.2);
    expect(patch.values['focalLength35mm'], 13);
  });

  testWidgets(
    'Apply & randomize feedback displays confirmation and auto-resets',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      await chooseProfile(tester);

      final applyBtn = find.byKey(const Key('applyProfile'));
      await tester.ensureVisible(applyBtn);
      expect(find.text('Apply & randomize'), findsOneWidget);
      expect(find.text('Applied'), findsNothing);

      await tester.tap(applyBtn);
      await tester.pump();

      expect(find.text('Applied'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Apply & randomize'), findsOneWidget);
      expect(find.text('Applied'), findsNothing);
    },
  );

  testWidgets(
    'post-processing results section remains on screen and supports export, share and icloud',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..importResult = fixture(kind: MediaKind.jpeg, status: null);
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      bridge.nextStatus = IntegrityStatus.verified;
      await tap(tester, 'process');

      expect(find.text('controlled.jpeg'), findsOneWidget);
      expect(find.byKey(const Key('exportFiles')), findsOneWidget);
      expect(find.byKey(const Key('shareFiles')), findsOneWidget);
      expect(find.byKey(const Key('openICloud')), findsOneWidget);
      expect(find.text('Process another file'), findsOneWidget);
      expect(find.textContaining('Processed Media'), findsOneWidget);

      await tap(tester, 'shareFiles');
      expect(bridge.shares, 1);

      await tap(tester, 'openICloud');
      expect(bridge.opens, 1);

      final anotherBtn = find.text('Process another file');
      await tester.ensureVisible(anotherBtn);
      await tester.pumpAndSettle();
      await tester.tap(anotherBtn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exportFiles')), findsNothing);
    },
  );

  testWidgets(
    'batch panel selection counts, deselect all, and select all work as expected',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [
          fixture(id: 's-1', kind: MediaKind.jpeg),
          fixture(id: 's-2', kind: MediaKind.heic),
          fixture(id: 's-3', kind: MediaKind.png),
        ];
      final controller = await launch(tester, bridge);
      expect(find.text('3 of 3 selected'), findsNothing);

      for (final s in controller.sessions) {
        controller.toggleBatch(s, true);
      }
      await tester.pumpAndSettle();
      expect(find.text('3 of 3 selected'), findsOneWidget);

      final deselectBtn = find.text('Deselect all');
      await tester.ensureVisible(deselectBtn);
      await tester.pumpAndSettle();
      await tester.tap(deselectBtn);
      await tester.pumpAndSettle();
      expect(controller.batchSelection, isEmpty);
      expect(find.text('0 of 3 selected'), findsOneWidget);

      final selectBtn = find.text('Select all');
      await tester.ensureVisible(selectBtn);
      await tester.pumpAndSettle();
      await tester.tap(selectBtn);
      await tester.pumpAndSettle();
      expect(controller.batchSelection.length, 3);
      expect(find.text('3 of 3 selected'), findsOneWidget);
    },
  );

  testWidgets('THE PHOTOS WORKFLOW card has restored green color scheme', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge);
    final workflowTitle = find.text('THE PHOTOS WORKFLOW');
    expect(workflowTitle, findsOneWidget);
    final textWidget = tester.widget<Text>(workflowTitle);
    expect(textWidget.style?.color, const Color(0xFF84E4C7));
  });

  testWidgets('importing multiple files navigates directly to batch editor', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..batchImportResult = [
        fixture(id: 's-1', kind: MediaKind.jpeg),
        fixture(id: 's-2', kind: MediaKind.png),
      ];
    final controller = await launch(tester, bridge);
    await tap(tester, 'importPhotos');
    await tester.pumpAndSettle();
    expect(controller.isBatchMode, isTrue);
    expect(find.text('Batch Editor'), findsOneWidget);
    expect(find.textContaining('2 files selected'), findsWidgets);

    final backBtn = find.byTooltip('Back to projects');
    expect(backBtn, findsOneWidget);
    await tester.tap(backBtn);
    await tester.pumpAndSettle();
    expect(controller.isBatchMode, isFalse);
    expect(find.text('LOCAL PROJECTS'), findsOneWidget);

    final editBtn = find.text('Edit selected files');
    await tester.ensureVisible(editBtn);
    await tester.pumpAndSettle();
    await tester.tap(editBtn);
    await tester.pumpAndSettle();
    expect(controller.isBatchMode, isTrue);
    expect(find.text('Batch Editor'), findsOneWidget);
  });

  testWidgets('saved camera profile autofills form on new session', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..importResult = fixture(id: 's-autofill', kind: MediaKind.jpeg);
    final controller = await launch(tester, bridge);
    await controller.rememberSelectedProfile(
      brand: 'Apple',
      profileId: 'apple-iphone-15-pro-max',
      cameraId: 'main',
    );
    await tap(tester, 'importPhotos');
    await tester.pumpAndSettle();

    expect(find.text('Apple'), findsOneWidget);
    expect(find.text('iPhone 15 Pro Max'), findsOneWidget);
    expect(find.text('Main Camera'), findsOneWidget);

    await tap(tester, 'process');
    final plan = bridge.sessions.single.processing!.metadataPatch!;
    expect(plan.values['make'], 'Apple');
    expect(plan.values['model'], 'iPhone 15 Pro Max');
    expect(plan.values['fNumber'], 1.78);
    expect(plan.values['lensModel'], contains('6.765mm'));
  });
}
