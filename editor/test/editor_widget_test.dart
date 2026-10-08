import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';

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

  testWidgets(
    'HEIC import → camera edit → acknowledgment → Files export → browser',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge);
      expect(find.text('Your media.\nYour metadata.'), findsOneWidget);
      await tap(tester, 'importPhotos');
      expect(find.text('controlled.heic'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('makeField')), 'Apple');
      await tester.enterText(
        find.byKey(const Key('modelField')),
        'Controlled Phone',
      );
      await tester.enterText(
        find.byKey(const Key('lensField')),
        'Controlled Lens',
      );
      await tap(tester, 'process');
      expect(bridge.receivedPatch?.lens, 'Controlled Lens');
      expect(find.text('Checks passed with limitations'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('exportFiles')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'acknowledge');
      await tap(tester, 'exportFiles');
      expect(bridge.exports, 1);
      expect(bridge.exportedAcknowledgment, isTrue);
      expect(find.textContaining('Copy saved to Files.'), findsOneWidget);
      await tap(tester, 'openICloud');
      expect(bridge.opens, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'video has provisional wording, no lens input and mismatch export disabled',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..importResult = fixture(kind: MediaKind.mov)
        ..nextStatus = IntegrityStatus.mismatch;
      await launch(tester, bridge);
      await tap(tester, 'importFiles');
      expect(find.byKey(const Key('lensField')), findsNothing);
      expect(
        find.textContaining('Video metadata support is provisional'),
        findsOneWidget,
      );
      await tap(tester, 'process');
      expect(find.text('Export blocked'), findsOneWidget);
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
