import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';

import 'fake_media_bridge.dart';

void main() {
  Future<EditorController> launch(
    WidgetTester tester, {
    FakeMediaBridge? bridge,
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(loadCameraProfiles);
    final controller = EditorController(bridge ?? FakeMediaBridge());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: MetadataEditorApp(controller: controller),
      ),
    );
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

  testWidgets('home and navigation fit a narrow phone at large text', (
    tester,
  ) async {
    await launch(tester, scale: 2);
    expect(find.text('Edit your metadata'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, 'tabErrorCodes');
    expect(find.text('Error codes'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, 'tabSettings');
    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tap(tester, 'tabEditor');
    expect(find.text('Edit your metadata'), findsOneWidget);
  });

  testWidgets('editing draft survives visits to both other tabs', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    await launch(tester, bridge: bridge);
    await tap(tester, 'importFiles');
    await tester.ensureVisible(find.text('Advanced metadata'));
    await tester.tap(find.text('Advanced metadata'));
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('modelMode'));
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('model')), 'Draft model');
    await tester.pumpAndSettle();
    await tap(tester, 'tabErrorCodes');
    await tap(tester, 'tabSettings');
    await tap(tester, 'tabEditor');
    expect(
      tester.widget<TextField>(find.byKey(const Key('model'))).controller!.text,
      'Draft model',
    );
    expect(bridge.processes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long error remains readable without displacing the home', (
    tester,
  ) async {
    final controller = await launch(tester, scale: 2);
    controller.error = List.filled(
      30,
      'The operation could not finish.',
    ).join(' ');
    controller.recordError(controller.error!, code: 'ERR_PROCESSING');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnosticErrorBanner')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, 'viewSolutionButton');
    expect(find.text('Error codes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear confirmation preserves published copies', (tester) async {
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    await launch(tester, bridge: bridge);
    await tester.ensureVisible(find.text('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('published Processed Media copies'),
      findsOneWidget,
    );
    expect(
      find.textContaining('copies exported elsewhere stay unchanged'),
      findsOneWidget,
    );
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(bridge.sessions, hasLength(1));
  });

  testWidgets(
    'unready recovery never builds an editor with stale capability data',
    (tester) async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = await launch(tester, bridge: bridge);
      controller.select(controller.sessions.single);
      await tester.pumpAndSettle();
      controller.capabilities = null;
      controller.operation = EditorOperation.loading;
      controller.recordError('Refreshing local history.');
      await tester.pump();
      expect(find.text('Retry startup'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Retry startup'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
