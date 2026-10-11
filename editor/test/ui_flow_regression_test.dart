import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
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
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> setField(WidgetTester tester, String key, String value) async {
    await tap(tester, '${key}Mode');
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.enterText(find.byKey(Key(key)), value);
    await tester.pumpAndSettle();
  }

  testWidgets('removing a batch source invalidates its frozen review plan', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..sessions = [fixture(), fixture(id: nextOutputId)];
    final controller = await launch(tester, bridge);
    controller.batchSelection.addAll(
      controller.sessions.map((session) => session.id),
    );
    controller.startBatchEditing();
    await tester.pumpAndSettle();
    await tap(tester, 'quickRemoveSoftware');
    await tap(tester, 'primaryeditAction');
    expect(find.textContaining('2 copies planned'), findsOneWidget);
    await tap(tester, 'returnToEdit');
    await controller.delete(
      controller.sessions.firstWhere((session) => session.id == sourceId),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'primaryeditAction');
    expect(find.textContaining('1 copies planned'), findsOneWidget);
    await tap(tester, 'primaryreviewAction');
    expect(bridge.processes, 1);
    expect(controller.queue.single.sessionId, nextOutputId);
    expect(controller.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fixed preset does not inherit randomized recipe dates', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = await launch(tester, bridge);
    final profile = (await loadCameraProfiles()).first;
    controller.presets = [
      SavedPreset(
        sourceId,
        'Random recipe',
        MetadataPatch(values: {'make': 'Recipe Make'}),
        recipe: ProfileRecipe(
          profile.id,
          profile.cameras.first.id,
          const RandomizationSettings(randomizeDates: true),
        ),
      ),
      SavedPreset(
        nextOutputId,
        'Fixed make',
        MetadataPatch(values: {'make': 'Fixed Make'}),
      ),
    ];
    controller.select(controller.sessions.single);
    await tester.pumpAndSettle();
    await tap(tester, 'profilesAndPresets');
    await tester.ensureVisible(find.text('Random recipe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Random recipe'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('dateIntentSegment')).last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<String>>(
            find.byKey(const Key('dateIntentSegment')).last,
          )
          .selected,
      {'randomize'},
    );
    await tester.ensureVisible(find.text('Fixed make'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixed make'));
    await tester.pumpAndSettle();
    await tap(tester, 'primaryeditAction');
    await tap(tester, 'primaryreviewAction');
    expect(controller.sessions.single.processing!.metadataPatch!.values, {
      'make': 'Fixed Make',
    });
    expect(
      controller.sessions.single.processing!.metadataPatch!.removals,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'batch processing preserves the draft date anchor across session reorder',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [
          fixture(additionalMetadata: {'offsetTimeOriginal': '+02:00'}),
          fixture(id: nextOutputId, kind: MediaKind.mp4),
        ]
        ..fieldsByFormat = {
          'heic': [
            'make',
            'software',
            'dateTimeOriginal',
            'offsetTimeOriginal',
          ],
          'mp4': ['make', 'software', 'dateTimeOriginal'],
        };
      final controller = await launch(tester, bridge);
      controller.batchSelection.addAll(
        controller.sessions.map((session) => session.id),
      );
      controller.startBatchEditing();
      await tester.pumpAndSettle();
      await tap(tester, 'advancedMetadata');
      await tester.ensureVisible(find.text('Dates'));
      await tester.tap(find.text('Dates'));
      await tester.pumpAndSettle();
      await setField(tester, 'dateTimeOriginal', '2026:04:05 10:00:00');
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      expect(
        controller.sessions.first.inspection.kind,
        MediaKind.mp4,
        reason:
            '${controller.error} / ${bridge.processes} / ${controller.queue.map((row) => row.status)}',
      );
      expect(
        tester.widget<MetadataForm>(find.byType(MetadataForm)).session.id,
        sourceId,
      );
      await tap(tester, 'primaryresultAction');
      await tap(tester, 'quickRemoveSoftware');
      await tap(tester, 'primaryeditAction');
      expect(find.byKey(const Key('primaryreviewAction')), findsOneWidget);
      bridge.nextProcessingId = 'second-batch-output';
      await tap(tester, 'primaryreviewAction');
      expect(bridge.processes, 4);
      final movie = controller.sessions.firstWhere(
        (session) => session.inspection.kind == MediaKind.mp4,
      );
      expect(
        DateTime.parse(
          movie.processing!.metadataPatch!.values['dateTimeOriginal']!
              as String,
        ).toUtc(),
        DateTime.utc(2026, 4, 5, 8),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
