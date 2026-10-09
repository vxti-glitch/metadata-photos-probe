import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_form.dart';
import 'package:metadata_editor/metadata_patch.dart';

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
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    final input = find.byKey(Key(field));
    await tester.ensureVisible(input);
    await tester.enterText(input, value);
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
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
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
      await tester.tap(brand);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apple').last);
      await tester.pumpAndSettle();
      final model = find.byKey(const ValueKey('model-Apple'));
      await tester.ensureVisible(model);
      final profile = (await loadCameraProfiles()).firstWhere(
        (p) => p.model == 'iPhone 15 Pro Max',
      );
      tester.widget<DropdownButtonFormField<String>>(model).onChanged!(
        profile.id,
      );
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
    await tester.tap(brand);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple').last);
    await tester.pumpAndSettle();
    final model = find.byKey(const ValueKey('model-Apple'));
    final profile = (await loadCameraProfiles()).firstWhere(
      (p) => p.model == 'iPhone 15 Pro Max',
    );
    tester.widget<DropdownButtonFormField<String>>(model).onChanged!(
      profile.id,
    );
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
      await chooseProfile(tester);
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Exposure').first);
      await tester.tap(find.text('Exposure').first);
      await tester.pumpAndSettle();
      final isoInput = find.byKey(const Key('iso'));
      final displayedISO = tester.widget<TextField>(isoInput).controller!.text;
      await tester.ensureVisible(isoInput);
      await tester.enterText(isoInput, '');
      await tester.enterText(isoInput, displayedISO);
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
    await tester.tap(find.text('Edit').first);
    await tester.pumpAndSettle();
    final dates = find.text('Dates');
    await tester.ensureVisible(dates);
    await tester.tap(dates);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('dateTimeOriginal'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '2024:03:05 10:15:00');
    final checkbox = find.byKey(const Key('automaticDates')).first;
    await tester.ensureVisible(checkbox);
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
}
