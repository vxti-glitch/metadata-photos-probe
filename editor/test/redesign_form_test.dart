import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_theme.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_form.dart';
import 'package:metadata_editor/metadata_patch.dart';

import 'fake_media_bridge.dart';
import 'form_test_helpers.dart';

class _TrackingBridge extends FakeMediaBridge {
  final patches = <String, List<MetadataPatch>>{};

  @override
  Future<MediaSession> processMetadata(String id, MetadataPatch patch) {
    patches.putIfAbsent(id, () => []).add(patch);
    return super.processMetadata(id, patch);
  }
}

class _DelayedHostBridge extends FakeMediaBridge {
  final host = Completer<Map<String, String>?>();

  @override
  Future<Map<String, String>?> getHostDevice() => host.future;
}

class _PartialFailureBridge extends FakeMediaBridge {
  bool failSecond = true;

  @override
  Future<MediaSession> processMetadata(String id, MetadataPatch patch) {
    if (failSecond && id == nextOutputId) {
      throw const FormatException('Temporary second-file failure.');
    }
    return super.processMetadata(id, patch);
  }
}

void main() {
  Future<EditorController> mount(
    WidgetTester tester,
    FakeMediaBridge bridge, {
    bool batch = false,
    ValueNotifier<bool>? light,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(loadCameraProfiles);
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    if (batch) {
      controller.batchSelection.addAll(controller.sessions.map((s) => s.id));
      controller.startBatchEditing();
    } else {
      controller.select(controller.sessions.single);
    }
    Widget build(bool isLight) => MaterialApp(
      theme: isLight ? AppTheme.lightTheme() : AppTheme.darkTheme(),
      home: Scaffold(
        body: MetadataForm(
          controller: controller,
          session: controller.selected!,
          batch: batch,
          fillAvailableSpace: true,
        ),
      ),
    );
    await tester.pumpWidget(
      light == null
          ? build(false)
          : ValueListenableBuilder<bool>(
              valueListenable: light,
              builder: (context, value, child) => build(value),
            ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return controller;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> reviewFiles(WidgetTester tester, Iterable<String> ids) async {
    for (final id in ids) {
      await tap(tester, 'reviewFile-$id');
    }
  }

  testWidgets(
    'automatic host profile prepares supported values without extra actions',
    (tester) async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = await mount(tester, bridge);
      expect(find.textContaining('Auto-matched'), findsOneWidget);
      expect(find.textContaining('Apple · iPhone 15 Pro Max'), findsOneWidget);
      expect(find.byKey(const Key('manualEditing')), findsOneWidget);
      expect(find.byKey(const Key('makeMode')), findsNothing);
      expect(find.text('Randomize all'), findsNothing);
      expect(bridge.processes, 0);
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      final output = controller.sessions.single.processing!;
      final patch = output.metadataPatch!;
      expect(patch.values['make'], 'Apple');
      expect(patch.values['model'], 'iPhone 15 Pro Max');
      expect(patch.values['iso'], isA<num>());
      expect(patch.values['exposureTime'], isA<num>());
      expect(patch.values['software'], isNotEmpty);
      expect(patch.values['dateTimeOriginal'], isNotEmpty);
      expect(patch.values['dateTimeOriginal'], patch.values['createDate']);
      expect(output.outputDisplayName, matches(RegExp(r'^IMG_\d{4}\.HEIC$')));
      expect(
        controller.sessions.single.inspection.metadata['make'],
        'Original Make',
      );
      expect(bridge.processes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic phone match takes precedence over a saved different model',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture()]
        ..editorState = {
          'schemaVersion': 1,
          'selectedProfileId': 'apple-iphone-15',
          'selectedCameraId': 'main',
          'selectedBrand': 'Apple',
        };
      final controller = await mount(tester, bridge);
      expect(find.textContaining('Apple · iPhone 15 Pro Max'), findsOneWidget);
      await tap(tester, 'chooseMainCamera');
      final profiles = await loadCameraProfiles();
      final profile = profiles.firstWhere(
        (p) => p.id == 'apple-iphone-15-pro-max',
      );
      final alternate = profile.cameras[1];
      await tester.tap(find.text(alternate.name).last);
      await tester.pumpAndSettle();
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      final patch = controller.sessions.single.processing!.metadataPatch!;
      expect(patch.values['model'], profile.model);
      for (final entry in alternate.fields.entries) {
        if (patch.values.containsKey(entry.key)) {
          expect(patch.values[entry.key], entry.value, reason: entry.key);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'every batch source receives the shared frozen patch and its reviewed filename',
    (tester) async {
      const third = '00000000-0000-4000-8000-000000000004';
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId), fixture(id: third)]
        ..nextStatus = IntegrityStatus.verified;
      final light = ValueNotifier(false);
      addTearDown(light.dispose);
      final controller = await mount(tester, bridge, batch: true, light: light);
      expect(find.text('3 files selected'), findsOneWidget);
      expect(find.text('Batch options'), findsNothing);
      await tap(tester, 'primaryeditAction');
      final reservedNames = Map<String, String>.of(bridge.reservedOutputNames);
      expect(reservedNames.keys.toSet(), {sourceId, nextOutputId, third});
      expect(reservedNames.values.toSet().length, 3);
      final originalState = tester.state(find.byType(MetadataForm));
      light.value = true;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(MetadataForm)), same(originalState));
      expect(bridge.reservedOutputNames, reservedNames);
      await tap(tester, 'returnToEdit');
      await tap(tester, 'primaryeditAction');
      expect(bridge.reservedOutputNames, reservedNames);
      await reviewFiles(tester, reservedNames.keys);
      final capturedDates = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .where(
            (tile) =>
                tile.title is Text &&
                (tile.title as Text).data == 'Captured date',
          )
          .map((tile) => (tile.subtitle as Text).data!.split('  →  ').last)
          .toSet();
      expect(capturedDates.length, 1);
      await tap(tester, 'primaryreviewAction');
      expect(bridge.processes, 3);
      expect(controller.queue.length, 3);
      expect(controller.queue.every((q) => q.status == 'completed'), isTrue);
      final outputs = controller.sessions.map((s) => s.processing!).toList();
      for (final session in controller.sessions) {
        expect(
          session.processing!.outputDisplayName,
          reservedNames[session.id],
        );
        expect(session.inspection.metadata['make'], 'Original Make');
        expect(
          session.processing!.metadataPatch!.equivalent(
            outputs.first.metadataPatch!,
          ),
          isTrue,
        );
        expect(
          session.processing!.metadataPatch!.values['dateTimeOriginal'],
          capturedDates.single,
        );
      }
      expect(outputs.map((p) => p.outputDisplayName).toSet().length, 3);
      await controller.retryBatch();
      expect(
        bridge.processes,
        3,
        reason: 'Completed copies are not processed again on retry',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown phone prepares dates without inventing brand or camera metadata',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture()]
        ..nextHostDevice = {
          'hardware': 'Unknown99,1',
          'model': 'Unknown phone',
        };
      final controller = await mount(tester, bridge);
      expect(
        find.textContaining('This phone could not be matched'),
        findsOneWidget,
      );
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      final patch = controller.sessions.single.processing!.metadataPatch!;
      expect(patch.values['dateTimeOriginal'], isNotEmpty);
      expect(patch.values.keys, isNot(contains('make')));
      expect(patch.values.keys, isNot(contains('model')));
      expect(patch.values.keys, isNot(contains('lensModel')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mixed batch applies compatible changes to each format and skips an unsupported item',
    (tester) async {
      const unsupported = '00000000-0000-4000-8000-000000000004';
      final bridge = FakeMediaBridge()
        ..sessions = [
          fixture(),
          fixture(id: nextOutputId, kind: MediaKind.mp4),
          fixture(id: unsupported, kind: MediaKind.png),
        ]
        ..fieldsByFormat = {
          'heic': [
            'make',
            'model',
            'iso',
            'dateTimeOriginal',
            'offsetTimeOriginal',
          ],
          'mp4': ['make', 'model', 'movieCreateDate'],
          'png': [],
        };
      final controller = await mount(tester, bridge, batch: true);
      await tap(tester, 'primaryeditAction');
      expect(find.textContaining('2 copies planned'), findsOneWidget);
      expect(find.text('No supported changes — skipped'), findsOneWidget);
      await tap(tester, 'primaryreviewAction');
      expect(bridge.processes, 2);
      final image = controller.sessions
          .firstWhere((s) => s.id == sourceId)
          .processing!
          .metadataPatch!;
      final video = controller.sessions
          .firstWhere((s) => s.id == nextOutputId)
          .processing!
          .metadataPatch!;
      expect(image.values['make'], video.values['make']);
      expect(image.values['model'], video.values['model']);
      expect(image.values['iso'], isA<num>());
      expect(video.values.keys, isNot(contains('iso')));
      expect(video.values.keys, isNot(contains('offsetTimeOriginal')));
      expect(video.values['movieCreateDate'], isNotEmpty);
      expect(
        controller.sessions.firstWhere((s) => s.id == unsupported).processing,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('exportReadyBatchCopies')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('acknowledgeBatchExport')), findsOneWidget);
      await tap(tester, 'acknowledgeBatchExport');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('exportReadyBatchCopies')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual exposure override survives changing the selected camera',
    (tester) async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = await mount(tester, bridge);
      await expandManualEditing(tester);
      await tap(tester, 'advancedMetadata');
      await tester.ensureVisible(find.text('Exposure'));
      await tester.tap(find.text('Exposure'));
      await tester.pumpAndSettle();
      await tap(tester, 'isoMode');
      await tester.tap(find.text('Set').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('iso')));
      await tester.enterText(find.byKey(const Key('iso')), '640');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tap(tester, 'chooseMainCamera');
      await tester.tap(find.text('Ultra Wide').last);
      await tester.pumpAndSettle();
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      final patch = controller.sessions.single.processing!.metadataPatch!;
      expect(patch.values['iso'], 640);
      expect(patch.values['fNumber'], 2.2);
      expect(patch.values['model'], 'iPhone 15 Pro Max');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch retry processes every failed file with the same frozen patch and filename',
    (tester) async {
      final bridge = _TrackingBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId)]
        ..processError = const FormatException('Temporary write failure.');
      final controller = await mount(tester, bridge, batch: true);
      await tap(tester, 'primaryeditAction');
      final names = Map<String, String>.of(bridge.reservedOutputNames);
      await tap(tester, 'primaryreviewAction');
      expect(bridge.processes, 2);
      expect(controller.queue.every((q) => q.status == 'failed'), isTrue);
      expect(bridge.reservedOutputNames, names);
      expect(controller.sessions.every((s) => s.processing == null), isTrue);
      bridge.processError = null;
      bridge.nextStatus = IntegrityStatus.verified;
      await controller.retryBatch();
      await tester.pumpAndSettle();
      expect(bridge.processes, 4);
      expect(controller.queue.every((q) => q.status == 'completed'), isTrue);
      for (final source in controller.sessions) {
        expect(source.processing!.outputDisplayName, names[source.id]);
        expect(bridge.patches[source.id]!.length, 2);
        expect(
          bridge.patches[source.id]!.first.equivalent(
            bridge.patches[source.id]!.last,
          ),
          isTrue,
        );
      }
      expect(
        bridge.patches[sourceId]!.first.equivalent(
          bridge.patches[nextOutputId]!.first,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retry requires fresh acknowledgment for new incomplete copies', (
    tester,
  ) async {
    final bridge = _PartialFailureBridge()
      ..sessions = [fixture(), fixture(id: nextOutputId)];
    final controller = await mount(tester, bridge, batch: true);
    await tap(tester, 'primaryeditAction');
    await tap(tester, 'primaryreviewAction');
    expect(
      controller.queue.where((q) => q.status == 'completed'),
      hasLength(1),
    );
    await tap(tester, 'acknowledgeBatchExport');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('exportReadyBatchCopies')))
          .onPressed,
      isNotNull,
    );
    bridge.failSecond = false;
    await tap(tester, 'retryUnfinishedBatch');
    expect(controller.queue.every((q) => q.status == 'completed'), isTrue);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('acknowledgeBatchExport')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('exportReadyBatchCopies')))
          .onPressed,
      isNull,
    );
    await tap(tester, 'acknowledgeBatchExport');
    await tap(tester, 'exportReadyBatchCopies');
    expect(bridge.exports, 1);
    expect(tester.takeException(), isNull);
  });

  for (final isLight in [false, true]) {
    testWidgets(
      'minimal editor and manual controls wrap at 320px and 2x text, light=$isLight',
      (tester) async {
        final bridge = FakeMediaBridge()..sessions = [fixture()];
        final light = ValueNotifier(isLight);
        addTearDown(light.dispose);
        await mount(tester, bridge, light: light);
        tester.view.physicalSize = const Size(320, 900);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expandManualEditing(tester);
        expect(tester.takeException(), isNull);
        await tap(tester, 'primaryeditAction');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'manual editing stays closed while phone matching is pending and becomes usable after fallback',
    (tester) async {
      final bridge = _DelayedHostBridge()..sessions = [fixture()];
      final controller = await mount(tester, bridge, settle: false);
      final manual = find.byKey(const Key('manualEditing'));
      expect(tester.widget<ExpansionTile>(manual).enabled, isFalse);
      await tester.ensureVisible(manual);
      await tester.tap(find.text('Manual editing'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('advancedMetadata')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('primaryeditAction')))
            .onPressed,
        isNull,
      );
      bridge.host.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget<ExpansionTile>(manual).enabled, isTrue);
      await expandManualEditing(tester);
      await tap(tester, 'advancedMetadata');
      await tap(tester, 'makeMode');
      await tester.tap(find.text('Set').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('make')));
      await tester.enterText(find.byKey(const Key('make')), 'Explicit Make');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      expect(
        controller.sessions.single.processing!.metadataPatch!.values['make'],
        'Explicit Make',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in IntegrityStatus.values) {
    testWidgets(
      'reopening a saved $status copy preserves its export qualification without processing again',
      (tester) async {
        final bridge = FakeMediaBridge()..sessions = [fixture(status: status)];
        await mount(tester, bridge);
        if (status == IntegrityStatus.mismatch) {
          expect(
            find.textContaining('failed integrity checks'),
            findsOneWidget,
          );
        } else {
          expect(find.text('Saved copy'), findsOneWidget);
        }
        expect(bridge.processes, 0);
        final export = find.byKey(const Key('exportFiles'));
        if (status == IntegrityStatus.verified) {
          expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
          await tap(tester, 'exportFiles');
          expect(bridge.exports, 1);
        } else if (status == IntegrityStatus.incomplete) {
          expect(tester.widget<FilledButton>(export).onPressed, isNull);
          await tap(tester, 'acknowledge');
          expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
          await tap(tester, 'exportFiles');
          expect(bridge.exportedAcknowledgment, isTrue);
          expect(bridge.exports, 1);
        } else {
          expect(tester.widget<FilledButton>(export).onPressed, isNull);
          expect(find.byKey(const Key('acknowledge')), findsNothing);
          expect(bridge.exports, 0);
        }
        expect(bridge.processes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'restored completed batch exports every saved copy without randomizing or processing again',
    (tester) async {
      final bridge = _TrackingBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId)]
        ..nextStatus = IntegrityStatus.verified;
      final original = await mount(tester, bridge, batch: true);
      await tap(tester, 'primaryeditAction');
      await tap(tester, 'primaryreviewAction');
      final names = {
        for (final s in original.sessions)
          s.id: s.processing!.outputDisplayName,
      };
      final patches = {
        for (final s in original.sessions) s.id: s.processing!.metadataPatch!,
      };
      expect(bridge.processes, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      final restored = await mount(tester, bridge, batch: true);
      expect(
        restored.queue.every((item) => item.status == 'completed'),
        isTrue,
      );
      expect(find.byKey(const Key('exportReadyBatchCopies')), findsOneWidget);
      await tap(tester, 'exportReadyBatchCopies');
      expect(bridge.exports, 1);
      expect(bridge.processes, 2);
      for (final s in restored.sessions) {
        expect(s.processing!.outputDisplayName, names[s.id]);
        expect(s.processing!.metadataPatch!.equivalent(patches[s.id]!), isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
