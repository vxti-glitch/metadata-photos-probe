import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_form.dart';
import 'package:metadata_editor/metadata_dates.dart';

import 'fake_media_bridge.dart';
import 'form_test_helpers.dart';

void main() {
  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<EditorController> mountBatch(
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
    await controller.initialize();
    controller.batchSelection.addAll(controller.sessions.map((s) => s.id));
    controller.startBatchEditing();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MetadataForm(
            controller: controller,
            session: controller.selected!,
            batch: true,
            fillAvailableSpace: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets(
    'five PNG screenshots receive shared randomized exposure and dates',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = List.generate(
          5,
          (index) => fixture(
            id: '00000000-0000-4000-8000-${(index + 10).toString().padLeft(12, '0')}',
            kind: MediaKind.png,
            additionalMetadata: {
              'iso': '65535',
              'dateTimeOriginal': '2001:01:01 00:00:00',
              'createDate': '2001:01:01 00:00:00',
              'modifyDate': '2001:01:01 00:00:00',
              'offsetTimeOriginal': index.isEven ? '-04:00' : '+09:00',
            },
          ),
        );
      final controller = await mountBatch(tester, bridge);
      await tap(tester, 'primaryeditAction');
      final names = Map<String, String>.of(bridge.reservedOutputNames);
      await tap(tester, 'primaryreviewAction');
      expect(bridge.processes, 5);
      expect(
        controller.queue.every((item) => item.status == 'completed'),
        isTrue,
      );
      expect(names.values.toSet(), hasLength(5));
      final first = controller.sessions.first.processing!.metadataPatch!;
      expect(first.values['make'], 'Apple');
      expect(first.values['model'], 'iPhone 15 Pro Max');
      expect(first.values['iso'], inInclusiveRange(40, 1000));
      expect(first.values['exposureTime'], greaterThan(0));
      expect(first.values['dateTimeOriginal'], isNot('2001:01:01 00:00:00'));
      expect(first.values['createDate'], first.values['dateTimeOriginal']);
      expect(first.values['modifyDate'], first.values['dateTimeOriginal']);
      for (final source in controller.sessions) {
        expect(source.processing!.metadataPatch!.equivalent(first), isTrue);
        expect(source.processing!.outputDisplayName, names[source.id]);
        expect(
          source.processing!.outputDisplayName,
          matches(r'^IMG_\d{4}\.PNG$'),
        );
        expect(source.inspection.metadata['iso'], '65535');
        expect(
          source.inspection.metadata['dateTimeOriginal'],
          '2001:01:01 00:00:00',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final matchedPhone in [true, false]) {
    testWidgets(
      'video-first automatic batch replaces source photo zones consistently matched=$matchedPhone',
      (tester) async {
        final bridge = FakeMediaBridge()
          ..sessions = [
            fixture(kind: MediaKind.mov),
            fixture(
              id: nextOutputId,
              kind: MediaKind.png,
              additionalMetadata: {'offsetTimeOriginal': '-04:00'},
            ),
            fixture(
              id: '00000000-0000-4000-8000-000000000004',
              kind: MediaKind.png,
              additionalMetadata: {'offsetTimeOriginal': '+09:00'},
            ),
          ];
        if (!matchedPhone) {
          bridge.nextHostDevice = {
            'hardware': 'Unknown99,1',
            'model': 'Unknown phone',
          };
        }
        final controller = await mountBatch(tester, bridge);
        await tap(tester, 'primaryeditAction');
        await tap(tester, 'primaryreviewAction');
        expect(bridge.processes, 3);
        final photos = controller.sessions
            .where((source) => source.inspection.kind.isImage)
            .map((source) => source.processing!.metadataPatch!)
            .toList();
        expect(photos.last.equivalent(photos.first), isTrue);
        final movie = controller.sessions
            .firstWhere((source) => !source.inspection.kind.isImage)
            .processing!
            .metadataPatch!;
        final photoInstant = datesForMedia(photos.first, image: false);
        expect(
          DateTime.parse(photoInstant.values['dateTimeOriginal'] as String)
              .difference(
                DateTime.parse(movie.values['dateTimeOriginal'] as String),
              )
              .inMicroseconds
              .abs(),
          lessThan(Duration.microsecondsPerSecond),
          reason: 'EXIF dates support whole seconds; ISO dates may retain fractions.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('video-first batch honors explicit per-photo Keep timezones', (
    tester,
  ) async {
    final bridge = FakeMediaBridge()
      ..sessions = [
        fixture(kind: MediaKind.mov),
        fixture(
          id: nextOutputId,
          kind: MediaKind.png,
          additionalMetadata: {'offsetTimeOriginal': '-04:00'},
        ),
        fixture(
          id: '00000000-0000-4000-8000-000000000004',
          kind: MediaKind.png,
          additionalMetadata: {'offsetTimeOriginal': '+09:00'},
        ),
      ];
    final controller = await mountBatch(tester, bridge);
    await expandManualEditing(tester);
    await tap(tester, 'advancedMetadata');
    await tester.ensureVisible(find.text('Dates'));
    await tester.tap(find.text('Dates'));
    await tester.pumpAndSettle();
    await tap(tester, 'offsetTimeOriginalMode');
    await tester.tap(find.text('Keep').last);
    await tester.pumpAndSettle();
    await tap(tester, 'primaryeditAction');
    await tap(tester, 'primaryreviewAction');
    expect(bridge.processes, 3);
    final movie = controller.sessions
        .firstWhere((source) => !source.inspection.kind.isImage)
        .processing!
        .metadataPatch!;
    for (final photo in controller.sessions.where(
      (source) => source.inspection.kind.isImage,
    )) {
      final patch = photo.processing!.metadataPatch!;
      expect(patch.values.containsKey('offsetTimeOriginal'), isFalse);
      expect(patch.removals.contains('offsetTimeOriginal'), isFalse);
      final instant = datesForMedia(
        patch,
        image: false,
        keptOffsets: photo.inspection.metadata,
      );
      expect(
        DateTime.parse(instant.values['dateTimeOriginal'] as String),
        DateTime.parse(movie.values['dateTimeOriginal'] as String),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
