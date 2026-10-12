import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_form.dart';

import 'fake_media_bridge.dart';
import 'form_test_helpers.dart';

void main() {
  testWidgets(
    'review freezes the resolved patch and supports returning to edit',
    (tester) async {
      await tester.runAsync(loadCameraProfiles);
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = EditorController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.select(controller.sessions.single);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: MetadataForm(
                    controller: controller,
                    session: controller.sessions.single,
                    fillAvailableSpace: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Review changes'), findsOneWidget);
      await expandManualEditing(tester);
      final advanced = find.byKey(const Key('advancedMetadata'));
      await tester.ensureVisible(advanced);
      await tester.tap(find.text('Advanced metadata'));
      await tester.pumpAndSettle();
      final makeMode = find.byKey(const Key('makeMode'));
      await tester.ensureVisible(makeMode);
      await tester.tap(makeMode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set').last);
      await tester.pumpAndSettle();
      final makeInput = find.byKey(const Key('make'));
      await tester.ensureVisible(makeInput);
      await tester.enterText(makeInput, 'Changed Make');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('primaryeditAction')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('primaryreviewAction')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reviewFile-$sourceId')));
      await tester.tap(find.byKey(const Key('reviewFile-$sourceId')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Original Make'), findsWidgets);
      expect(find.textContaining('Changed Make'), findsWidgets);

      await tester.tap(find.byKey(const Key('returnToEdit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('primaryeditAction')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('primaryreviewAction')), findsOneWidget);

      await tester.tap(find.byKey(const Key('primaryreviewAction')));
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );
      await tester.pumpAndSettle();
      expect(bridge.processes, 1);
      expect(
        controller.sessions.single.processing?.metadataPatch?.values['make'],
        'Changed Make',
      );
      expect(
        controller.sessions.single.processing?.metadataPatch?.values.keys,
        contains('dateTimeOriginal'),
      );
      expect(find.byKey(const Key('primaryresultAction')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('randomized dates stay frozen when returning to edit', (
    tester,
  ) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    await tester.ensureVisible(find.text('Randomize').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Randomize').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryeditAction')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('reviewFile-$sourceId')));
    await tester.tap(find.byKey(const Key('reviewFile-$sourceId')));
    await tester.pumpAndSettle();
    String captureDate() {
      final dateTile = find.ancestor(
        of: find.text('Captured date'),
        matching: find.byType(ListTile),
      );
      return (tester.widget<ListTile>(dateTile).subtitle as Text).data!;
    }

    final firstReviewDate = captureDate();
    await tester.tap(find.byKey(const Key('returnToEdit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryeditAction')));
    await tester.pumpAndSettle();
    final reviewFile = find.byKey(const Key('reviewFile-$sourceId'));
    if (find.text('Captured date').evaluate().isEmpty) {
      await tester.ensureVisible(reviewFile);
      await tester.tap(reviewFile);
      await tester.pumpAndSettle();
    }
    expect(captureDate(), firstReviewDate);
  });

  testWidgets('canceling Set date preserves the current draft intent', (
    tester,
  ) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    final advanced = find.byKey(const Key('advancedMetadata'));
    await tester.ensureVisible(advanced);
    await tester.tap(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    final dates = find.text('Dates');
    await tester.ensureVisible(dates);
    await tester.tap(dates);
    await tester.pumpAndSettle();
    final dateMode = find.byKey(const Key('dateTimeOriginalMode'));
    await tester.ensureVisible(dateMode);
    await tester.tap(dateMode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    final dateInput = find.byKey(const Key('dateTimeOriginal'));
    await tester.ensureVisible(dateInput);
    await tester.enterText(dateInput, '2020:01:02 03:04:05');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    final setIntent = find.descendant(
      of: find.byKey(const Key('dateIntentSegment')),
      matching: find.text('Set'),
    );
    await tester.ensureVisible(setIntent);
    await tester.pumpAndSettle();
    await tester.tap(setIntent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Custom date edits or removals are staged in Advanced metadata.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(dateInput).controller!.text,
      '2020:01:02 03:04:05',
    );
  });

  testWidgets(
    'mixed video-first batch skips unchanged files and resets acknowledgment',
    (tester) async {
      await tester.runAsync(loadCameraProfiles);
      final bridge = FakeMediaBridge()
        ..sessions = [
          fixture(kind: MediaKind.mp4, status: IntegrityStatus.verified),
          fixture(
            id: nextOutputId,
            kind: MediaKind.heic,
            status: IntegrityStatus.verified,
          ),
        ]
        ..fieldsByFormat = {
          'mp4': [],
          'heic': ['make', 'model', 'lensModel', 'dateTimeOriginal'],
        }
        ..nextProcessingId = 'processing-first';
      final controller = EditorController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.batchSelection.addAll(controller.sessions.map((s) => s.id));
      controller.startBatchEditing();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: MetadataForm(
                    controller: controller,
                    session: controller.selected!,
                    batch: true,
                    fillAvailableSpace: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expandManualEditing(tester);
      final advanced = find.byKey(const Key('advancedMetadata'));
      await tester.ensureVisible(advanced);
      await tester.tap(find.text('Advanced metadata'));
      await tester.pumpAndSettle();
      final lensMode = find.byKey(const Key('lensModelMode'));
      await tester.ensureVisible(lensMode);
      await tester.tap(lensMode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set').last);
      await tester.pumpAndSettle();
      final lensInput = find.byKey(const Key('lens'));
      await tester.ensureVisible(lensInput);
      await tester.enterText(lensInput, 'Portrait lens');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('primaryeditAction')));
      await tester.pumpAndSettle();
      expect(find.text('No supported changes — skipped'), findsOneWidget);
      await tester.tap(find.byKey(const Key('primaryreviewAction')));
      await tester.pumpAndSettle();
      expect(bridge.processes, 1);
      expect(controller.queue.single.sessionId, nextOutputId);
      expect(
        controller.sessions.firstWhere((s) => s.id == sourceId).processing,
        isNotNull,
      );
      expect(find.text('Unchanged — no copy created'), findsOneWidget);
      expect(find.textContaining('Matches'), findsOneWidget);
      expect(
        find.textContaining('Opaque metadata not qualified.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('acknowledgeBatchExport')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('primaryresultAction')));
      await tester.pumpAndSettle();
      controller.batchSelection.remove(sourceId);
      await tester.tap(find.byKey(const Key('primaryeditAction')));
      await tester.pumpAndSettle();
      bridge.nextProcessingId = 'processing-second';
      expect(find.text('controlled.mp4'), findsNothing);
      expect(find.text('controlled.heic'), findsOneWidget);
      await tester.tap(find.byKey(const Key('primaryreviewAction')));
      await tester.pumpAndSettle();
      expect(bridge.processes, 2);
      expect(controller.queue.single.sessionId, nextOutputId);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('acknowledgeBatchExport')),
            )
            .value,
        isFalse,
      );
    },
  );
  testWidgets('removing a date shows a custom intent, not Keep', (
    tester,
  ) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    final advanced = find.byKey(const Key('advancedMetadata'));
    await tester.ensureVisible(advanced);
    await tester.tap(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    final dates = find.text('Dates');
    await tester.ensureVisible(dates);
    await tester.tap(dates);
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('dateTimeOriginalMode'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Custom date edits or removals are staged in Advanced metadata.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SegmentedButton<String>>(
            find.byKey(const Key('dateIntentSegment')),
          )
          .selected,
      isEmpty,
    );
  });

  testWidgets('busy processing disables Back to edit', (tester) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    bridge.metadataLease = Completer<void>();
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    await tester.ensureVisible(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('makeMode'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('make'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'Changed Make');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryeditAction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryreviewAction')));
    await tester.pump();
    expect(controller.busy, isTrue);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('returnToEdit')))
          .onPressed,
      isNull,
    );
    bridge.metadataLease!.complete();
    await tester.pumpAndSettle();
    expect(controller.busy, isFalse);
  });

  testWidgets('failed reprocessing never labels retained output as new', (
    tester,
  ) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()
      ..sessions = [fixture(status: IntegrityStatus.verified)]
      ..processError = const FormatException('Processing failed.');
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saved copy'), findsOneWidget);
    await tester.tap(find.byKey(const Key('primaryresultAction')));
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    await tester.ensureVisible(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('makeMode'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('make'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'New Make');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryeditAction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('primaryreviewAction')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No processed copy is available. Review the error, then edit and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Copy created'), findsNothing);
    expect(controller.sessions.single.processing, isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('exportFiles')))
          .onPressed,
      isNull,
    );
  });
  testWidgets('accepted quick Set date remains selected and can be changed', (
    tester,
  ) async {
    await tester.runAsync(loadCameraProfiles);
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: MetadataForm(
                  controller: controller,
                  session: controller.sessions.single,
                  fillAvailableSpace: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expandManualEditing(tester);
    final setIntent = find.descendant(
      of: find.byKey(const Key('dateIntentSegment')),
      matching: find.text('Set'),
    );
    await tester.ensureVisible(setIntent);
    await tester.pumpAndSettle();
    await tester.tap(setIntent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<String>>(
            find.byKey(const Key('dateIntentSegment')),
          )
          .selected,
      {'set'},
    );
    expect(find.byKey(const Key('changeCaptureDate')), findsOneWidget);
  });
}
