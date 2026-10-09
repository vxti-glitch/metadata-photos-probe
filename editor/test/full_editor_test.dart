import 'dart:math';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_patch.dart';
import 'package:metadata_editor/metadata_dates.dart';

import 'fake_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full field changes and explicit removal roundtrip; overlap rejected',
    () {
      final patch = MetadataPatch(
        values: {
          'iso': 800,
          'exposureTime': 1 / 120,
          'fNumber': 1.78,
          'latitude': 35.5,
          'longitude': -78.5,
          'lensModel': 'Test lens',
        },
        removals: ['software'],
      );
      expect(MetadataPatch.decode(patch.toMap()).equivalent(patch), isTrue);
      expect(
        MetadataPatch(values: {'iso': 800}, removals: ['iso']).validate(),
        isNotNull,
      );
      expect(MetadataPatch(values: {'latitude': 91}).validate(), isNotNull);
      expect(
        MetadataPatch(values: {'exposureTime': double.infinity}).validate(),
        isNotNull,
      );
      expect(
        MetadataPatch.parseField(
          metadataFields.firstWhere((f) => f.key == 'exposureTime'),
          '1/240',
        ),
        1 / 240,
      );
      expect(
        MetadataPatch(values: {'dateTimeOriginal': '2026:02:31 12:00:00'})
            .validate(),
        isNotNull,
      );
    },
  );
  test('catalog identifiers, evidence and camera metadata are valid', () async {
    final profiles = await loadCameraProfiles();
    expect(
      profiles.map((p) => p.brand).toSet(),
      containsAll(['Apple', 'Samsung', 'Google']),
    );
    expect(
      profiles.map((p) => p.model),
      containsAll(['iPhone 15', 'iPhone 15 Pro', 'iPhone 15 Pro Max']),
    );
    for (final profile in profiles) {
      expect(profile.sources, isNotEmpty);
      for (final camera in profile.cameras) {
        final patch = const RandomizationSettings().generate(
          profile,
          camera,
          MediaKind.heic,
          Random(10),
          DateTime.utc(2026, 10, 8),
        );
        expect(patch.validate(), isNull, reason: '${profile.id}/${camera.id}');
        expect(patch.values['make'], profile.make);
        expect(patch.values['model'], profile.model);
        expect(patch.values['fNumber'], camera.fields['fNumber']);
        expect(
          patch.values.keys,
          containsAll(['iso', 'exposureTime', 'dateTimeOriginal']),
        );
        expect(patch.values.keys, isNot(contains('latitude')));
      }
    }
  });
  test('randomization is coherent, independent and bounded, format filter is respected', () {
    final profile = CameraProfile(
      'apple-test',
      'Apple',
      'Test Phone',
      'Apple',
      'Apple',
      [
        ProfileCamera('main', 'Main', {
          'fNumber': 1.78,
          'focalLength': 6.765,
          'lensModel': 'Main',
        }, {}),
      ],
      ['https://example.invalid'],
      {},
    );
    const settings = RandomizationSettings(
      isoMin: 100,
      isoMax: 120,
      pastDays: 5,
      latitude: 45,
      longitude: 179.999,
      locationRadiusMeters: 1000,
    );
    final random = Random(1), now = DateTime.utc(2026, 10, 8);
    final results = List.generate(
      30,
      (_) => settings.generate(
        profile,
        profile.cameras.first,
        MediaKind.jpeg,
        random,
        now,
      ),
    );
    for (final patch in results) {
      expect(patch.values['iso'], inInclusiveRange(100, 120));
      expect(patch.values['longitude'], inInclusiveRange(-180, 180));
      expect(patch.values['fNumber'], 1.78);
      expect(patch.validate(), isNull);
    }
    expect(
      results.map((p) => p.values['dateTimeOriginal']).toSet().length,
      greaterThan(1),
    );
    final video = settings.generate(
      profile,
      profile.cameras.first,
      MediaKind.mov,
      Random(2),
      now,
      supportedFields: {
        'make',
        'model',
        'lensModel',
        'movieCreateDate',
        'latitude',
        'longitude',
      },
    );
    expect(video.values.keys, isNot(contains('iso')));
    expect(video.values.keys, isNot(contains('fNumber')));
    expect(video.values.keys, contains('movieCreateDate'));
  });
  test(
    'saved presets survive controller restart; failed write rolls back',
    () async {
      final bridge = FakeMediaBridge();
      final controller = EditorController(bridge);
      await controller.initialize();
      final patch = MetadataPatch(
        values: {'make': 'Apple', 'iso': 250},
        removals: ['artist'],
      );
      await controller.savePreset('My camera', patch);
      expect(controller.presets.length, 1);
      final restored = EditorController(bridge);
      await restored.initialize();
      expect(restored.presets.single.patch.equivalent(patch), isTrue);
      bridge.stateSaveError = Exception('Full disk');
      await restored.deletePreset(restored.presets.single);
      expect(restored.presets.length, 1);
      expect(restored.error, isNotNull);
      controller.dispose();
      restored.dispose();
    },
  );
  test(
    'batch processes each immutable plan and recovers completed work',
    () async {
      const second = '00000000-0000-4000-8000-000000000010';
      final bridge = FakeMediaBridge()
        ..nextStatus = IntegrityStatus.verified
        ..batchImportResult = [
          fixture(),
          fixture(id: second, kind: MediaKind.jpeg),
        ];
      final controller = EditorController(bridge);
      await controller.initialize();
      await controller.importBatch(photos: true);
      expect(controller.sessions.length, 2);
      expect(controller.batchSelection.length, 2);
      await controller.processBatch({
        sourceId: MetadataPatch(values: {'iso': 200}),
        second: MetadataPatch(values: {'iso': 800}),
      });
      expect(bridge.processes, 2);
      expect(controller.queue.every((q) => q.status == 'completed'), isTrue);
      final restored = EditorController(bridge);
      await restored.initialize();
      expect(restored.queue.length, 2);
      expect(restored.sessions.every((s) => s.processing != null), isTrue);
      await restored.exportSelectedBatch();
      expect(bridge.exports, 1);
      await restored.retryBatch();
      expect(bridge.processes, 2);
      controller.dispose();
      restored.dispose();
    },
  );
  test('interrupted queue recovers without automatic processing, failed items can retry', () async {
    final patch = MetadataPatch(values: {'make': 'Apple'});
    final bridge = FakeMediaBridge()
      ..sessions = [fixture()]
      ..editorState = {
        'schemaVersion': 1,
        'presets': [],
        'selection': [sourceId],
        'queue': [QueueItem(sourceId, patch, status: 'running').toMap()],
      };
    final controller = EditorController(bridge);
    await controller.initialize();
    expect(controller.queue.single.status, 'interrupted');
    expect(bridge.processes, 0);
    bridge.processError = Exception('Read error');
    await controller.retryBatch();
    expect(controller.queue.single.status, 'failed');
    bridge.processError = null;
    await controller.retryBatch();
    expect(controller.queue.single.status, 'completed');
    controller.dispose();
  });
  test(
    'recipe preferences persist and reject contradictory imported intents',
    () async {
      final profiles = await loadCameraProfiles();
      final p = profiles.first;
      final c = p.cameras.first;
      final recipe = ProfileRecipe(
        p.id,
        c.id,
        const RandomizationSettings(isoMin: 200, isoMax: 400, pastDays: 10),
        overrides: MetadataPatch(values: {'artist': 'My name'}),
        keepFields: {'latitude', 'longitude'},
      );
      final patch = recipe.settings.generate(
        p,
        c,
        MediaKind.jpeg,
        Random(1),
        DateTime.utc(2026, 10, 8),
      );
      final bridge = FakeMediaBridge();
      final editor = EditorController(bridge);
      await editor.initialize();
      await editor.savePreset('Camera recipe', patch, recipe: recipe);
      final restored = EditorController(bridge);
      await restored.initialize();
      final saved = restored.presets.single.recipe!;
      expect(saved.settings.isoMin, 200);
      expect(saved.settings.isoMax, 400);
      expect(saved.overrides!.values['artist'], 'My name');
      expect(saved.keepFields, contains('latitude'));
      expect(
        () => ProfileRecipe.decode({
          ...recipe.toMap(),
          'keepFields': ['artist'],
        }),
        throwsFormatException,
      );
      expect(
        () => RandomizationSettings.decode({
          ...recipe.settings.toMap(),
          'shutters': [double.nan],
        }),
        throwsFormatException,
      );
      editor.dispose();
      restored.dispose();
    },
  );
  test(
    'stale completed queue never certifies a replaced native output',
    () async {
      final wanted = MetadataPatch(values: {'iso': 200});
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(status: IntegrityStatus.verified)]
        ..editorState = {
          'schemaVersion': 1,
          'presets': [],
          'queue': [QueueItem(sourceId, wanted, status: 'completed').toMap()],
        };
      final editor = EditorController(bridge);
      await editor.initialize();
      expect(editor.queue.single.status, 'interrupted');
      expect(bridge.processes, 0);
      editor.dispose();
    },
  );
  test('failed batch edit discards stale source output and refreshes native history', () async {
    final bridge = FakeMediaBridge()
      ..sessions = [fixture(status: IntegrityStatus.verified)]
      ..processError = Exception('Native write failed');
    final editor = EditorController(bridge);
    await editor.initialize();
    await editor.processBatch({
      sourceId: MetadataPatch(values: {'iso': 200}),
    });
    expect(editor.sessions.single.processing, isNull);
    expect(editor.queue.single.status, 'failed');
    expect(editor.canExport, isFalse);
    editor.dispose();
  });
  test(
    'batch cancellation keeps its lease and frozen plan, skips remaining items',
    () async {
      const second = '00000000-0000-4000-8000-000000000010';
      final lease = Completer<void>();
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: second)]
        ..metadataLease = lease;
      final editor = EditorController(bridge);
      await editor.initialize();
      final patch = MetadataPatch(values: {'iso': 200});
      final run = editor.processBatch({
        sourceId: patch,
        second: MetadataPatch(values: {'iso': 800}),
      });
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
        if (bridge.processes == 1) break;
      }
      await editor.cancel();
      expect(editor.busy, isTrue);
      expect(editor.cancellationRequested, isTrue);
      lease.complete();
      await run;
      expect(bridge.processes, 1);
      expect(editor.queue.every((q) => q.status == 'interrupted'), isTrue);
      expect(editor.queue.first.patch.equivalent(patch), isTrue);
      expect(editor.acknowledged, isFalse);
      editor.dispose();
    },
  );
  test('automatic dates off generates no date writes; explicit manual override remains', () async {
    final profile = (await loadCameraProfiles()).first;
    final camera = profile.cameras.first;
    const original = RandomizationSettings();
    final off = original.withAutomaticDates(false);
    for (final kind in [
      MediaKind.jpeg,
      MediaKind.heic,
      MediaKind.mp4,
      MediaKind.mov,
    ]) {
      final generated = off.generate(
        profile,
        camera,
        kind,
        Random(1),
        DateTime.utc(2026, 10, 8),
      );
      expect(
        generated.values.keys.any(
          (key) =>
              key.toLowerCase().contains('date') ||
              key.startsWith('offsetTime'),
        ),
        isFalse,
      );
      final date = kind.isImage
          ? '2024:03:05 10:15:00'
          : '2024-03-05T10:15:00Z';
      final recipe = ProfileRecipe(
        profile.id,
        camera.id,
        off,
        overrides: MetadataPatch(values: {'dateTimeOriginal': date}),
      );
      expect(
        applyRecipeOverrides(generated, recipe).values['dateTimeOriginal'],
        date,
      );
    }
  });
  test('manual calendar selection writes coherent wall time/offset or video UTC dates', () {
    final date = DateTime.utc(2024, 3, 5, 10, 15);
    final photo = captureDatePatch(date, image: true);
    expect(photo.values['dateTimeOriginal'], '2024:03:05 10:15:00');
    expect(photo.values['createDate'], photo.values['dateTimeOriginal']);
    expect(photo.values['offsetTimeOriginal'], '+00:00');
    expect(photo.validate(), isNull);
    final video = captureDatePatch(date, image: false);
    expect(video.values['movieCreateDate'], '2024-03-05T10:15:00.000Z');
    expect(video.values['dateTimeOriginal'], video.values['mediaModifyDate']);
    expect(video.values.keys.any((k) => k.startsWith('offsetTime')), isFalse);
    expect(MetadataPatch(values: {'fNumber': 0.001}).validate(), isNotNull);
    expect(
      MetadataPatch(values: {'imageDirection': 359.9999999}).validate(),
      isNotNull,
    );
  });
}
