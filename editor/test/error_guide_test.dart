import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/settings_screen.dart';

import 'fake_media_bridge.dart';

void main() {
  late FakeMediaBridge bridge;
  late EditorController controller;
  setUp(() async {
    bridge = FakeMediaBridge();
    controller = EditorController(bridge);
    await controller.initialize();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('compact settings keeps details collapsed until requested', (
    tester,
  ) async {
    await pumpScreen(tester, SettingsScreen(controller: controller));
    expect(find.text('STORAGE & PRESETS'), findsOneWidget);
    expect(find.text('Swift Media Engine'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('engineDetails')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Engine & diagnostics'));
    await tester.tap(find.text('Engine & diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Swift Media Engine'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest issue opens steps and can return to the editor', (
    tester,
  ) async {
    var returned = false;
    controller.recordError('Processing failed', code: 'ERR_PROCESSING');
    await pumpScreen(
      tester,
      Scaffold(
        body: ErrorGuideSheet(
          isModal: false,
          controller: controller,
          onOpenEditor: () => returned = true,
        ),
      ),
    );
    final cause = kErrorGuideCatalog
        .firstWhere((entry) => entry.code == 'ERR_PROCESSING')
        .cause;
    expect(find.text(cause), findsNothing);
    await tester.tap(find.byKey(const Key('viewLatestSteps')));
    await tester.pumpAndSettle();
    expect(find.text(cause), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('returnToEditorFromGuide')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('returnToEditorFromGuide')));
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup recovery remains available after clearing error history', (
    tester,
  ) async {
    controller.capabilities = null;
    controller.recordError('Startup failed');
    controller.clearLastError();
    // Controller setup creates its persistence tail outside the widget fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await pumpScreen(
      tester,
      Scaffold(body: ErrorGuideSheet(isModal: false, controller: controller)),
    );
    expect(find.text('Startup required'), findsOneWidget);
    expect(find.textContaining('This code has no catalog entry'), findsNothing);
    await tester.tap(find.byKey(const Key('retryStartupFromGuide')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      controller.ready,
      isTrue,
      reason:
          '${controller.error} / ${controller.operation} / ${bridge.editorState}',
    );
    expect(find.byKey(const Key('retryStartupFromGuide')), findsNothing);
  });

  testWidgets('busy startup disables retry from the guide', (tester) async {
    controller.capabilities = null;
    controller.operation = EditorOperation.loading;
    await pumpScreen(
      tester,
      Scaffold(body: ErrorGuideSheet(isModal: false, controller: controller)),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('retryStartupFromGuide')))
          .onPressed,
      isNull,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('Settings fits 360px with text scale $scale and recent error', (
      tester,
    ) async {
      controller.recordError('Integrity verification mismatch');
      await pumpScreen(
        tester,
        SettingsScreen(controller: controller),
        scale: scale,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('engineDetails')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const Key('engineDetails')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Engine & diagnostics'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('privacyGuaranteeRow')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('Guide fits 360px with text scale $scale and keyboard', (
      tester,
    ) async {
      controller.recordError('Integrity verification mismatch');
      await pumpScreen(
        tester,
        Scaffold(body: ErrorGuideSheet(isModal: false, controller: controller)),
        scale: scale,
        keyboard: 280,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('errorSearchInput')));
      await tester.enterText(
        find.byKey(const Key('errorSearchInput')),
        'no matching code',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching error codes found'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final search = tester.widget<TextField>(
        find.byKey(const Key('errorSearchInput')),
      );
      expect(search.controller!.text, 'no matching code');
    });
  }

  testWidgets('Every catalog category is available including Processing', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(body: ErrorGuideSheet(isModal: false)),
    );
    expect(
      find.textContaining('${kErrorGuideCatalog.length} error codes'),
      findsOneWidget,
    );
    for (final category
        in kErrorGuideCatalog.map((item) => item.category).toSet()) {
      expect(find.byKey(Key('categoryPill_$category')), findsOneWidget);
    }
    await tester.ensureVisible(
      find.byKey(const Key('categoryPill_Processing')),
    );
    await tester.tap(find.byKey(const Key('categoryPill_Processing')));
    await tester.pumpAndSettle();
    expect(find.text('ERR_PROCESSING'), findsOneWidget);
    expect(find.text('ERR_DATE_FMT'), findsNothing);
  });

  testWidgets(
    'New controller error clears filters and promotes matching guide',
    (tester) async {
      await pumpScreen(
        tester,
        Scaffold(body: ErrorGuideSheet(isModal: false, controller: controller)),
      );
      await tester.enterText(find.byKey(const Key('errorSearchInput')), 'gps');
      await tester.pumpAndSettle();
      controller.recordError('Integrity verification mismatch');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('errorSearchInput')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_MEDIA_INTEGRITY')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('viewLatestSteps')));
      await tester.tap(find.byKey(const Key('viewLatestSteps')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          kErrorGuideCatalog
              .firstWhere((item) => item.code == 'ERR_MEDIA_INTEGRITY')
              .cause,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Modal guide follows live controller error over opening highlight',
    (tester) async {
      controller.recordError(
        'Latitude must be between -90 and 90',
        code: 'ERR_GPS_BOUNDS',
      );
      await pumpScreen(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openErrorGuideSheet(
                context,
                highlightedCode: 'ERR_GPS_BOUNDS',
                controller: controller,
              ),
              child: const Text('Open guide'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open guide'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_GPS_BOUNDS')),
        findsOneWidget,
      );

      controller.recordError(
        'Processing could not finish',
        code: 'ERR_PROCESSING',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_PROCESSING')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_GPS_BOUNDS')),
        findsNothing,
      );
      await tester.ensureVisible(find.byKey(const Key('viewLatestSteps')));
      await tester.tap(find.byKey(const Key('viewLatestSteps')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          kErrorGuideCatalog
              .firstWhere((item) => item.code == 'ERR_PROCESSING')
              .cause,
        ),
        findsOneWidget,
      );

      controller.clearLastError();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_PROCESSING')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_GPS_BOUNDS')),
        findsNothing,
      );
      expect(find.text('JUST ENCOUNTERED'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Updated highlighted code promotes a reused guide', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(
        body: ErrorGuideSheet(isModal: false, highlightedCode: 'ERR_DATE_FMT'),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ErrorGuideSheet(
            isModal: false,
            highlightedCode: 'ERR_PROCESSING',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('justEncounteredBadge_ERR_PROCESSING')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('viewLatestSteps')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        kErrorGuideCatalog
            .firstWhere((item) => item.code == 'ERR_PROCESSING')
            .cause,
      ),
      findsOneWidget,
    );
  });

  testWidgets('Busy and unavailable engine disable actual settings handlers', (
    tester,
  ) async {
    for (final busy in [true, false]) {
      controller.operation = busy ? EditorOperation.processing : null;
      if (!busy) controller.capabilities = null;
      await pumpScreen(
        tester,
        SettingsScreen(key: UniqueKey(), controller: controller),
      );
      for (final key in [
        'visitWebsiteRow',
        'clearCacheRow',
        'resetPresetsRow',
      ]) {
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(Key(key)),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.widget<InkWell>(find.byKey(Key(key))).onTap, isNull);
      }
      for (final key in ['clearCacheButton', 'resetPresetsButton']) {
        expect(
          tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
    }
    expect(bridge.clears, 0);
    expect(bridge.openedUrls, isEmpty);
  });

  testWidgets('Settings displays cache success locally', (tester) async {
    await pumpScreen(tester, SettingsScreen(controller: controller));
    await tester.scrollUntilVisible(
      find.byKey(const Key('clearCacheButton')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clearCacheButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmClearCacheButton')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(controller.notice, contains('Local projects cleared.'));
    await tester.drag(find.byType(ListView).first, const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Local projects cleared.'), findsOneWidget);
  });

  testWidgets('Settings displays clear and reset failures locally', (
    tester,
  ) async {
    bridge.clearAfterCommitError = StateError('Unable to clear local copies');
    await tester.runAsync(controller.clearCache);
    await pumpScreen(tester, SettingsScreen(controller: controller));
    expect(find.byKey(const Key('settingsOperationError')), findsOneWidget);
    bridge.stateSaveError = StateError('Unable to save presets');
    await tester.runAsync(controller.resetPresets);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settingsOperationError')), findsOneWidget);
    expect(controller.notice, isNull);
  });

  testWidgets('Settings keeps unsaved history warning visible', (tester) async {
    controller.statePersistenceError =
        'Preferences and local history could not be saved.';
    await pumpScreen(tester, SettingsScreen(controller: controller));
    expect(find.byKey(const Key('settingsPersistenceWarning')), findsOneWidget);
    expect(find.textContaining('could not be saved'), findsOneWidget);
  });

  testWidgets('Unknown recent error offers guidance without promising a fix', (
    tester,
  ) async {
    controller.lastErrorCode = 'ERR_UNKNOWN_TEST';
    controller.lastErrorMessage = 'A diagnostic stage is unavailable.';
    await pumpScreen(tester, SettingsScreen(controller: controller));
    await tester.scrollUntilVisible(
      find.byKey(const Key('recentErrorBanner')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ERR_UNKNOWN_TEST'), findsOneWidget);
    expect(find.text('ACTIVE FIX AVAILABLE'), findsNothing);
    expect(find.text('DIAGNOSTIC STEPS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Attribution explanation is scrollable and does not promise label suppression',
    (tester) async {
      await pumpScreen(
        tester,
        SettingsScreen(controller: controller),
        scale: 2,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('photosAttributionRow')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('photosAttributionRow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photosAttributionRow')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      expect(
        find.textContaining(
          'does not write processed copies directly to Photos',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('zero third-party attribution'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
