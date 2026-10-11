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
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 640);
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

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openCatalog(WidgetTester tester) async {
    if (find.byKey(const Key('errorSearchInput')).evaluate().isEmpty) {
      await tapKey(tester, 'browseErrorCatalog');
    }
  }

  Future<void> selectCategory(WidgetTester tester, String category) async {
    await tapKey(tester, 'errorCategoryFilter');
    await tester.tap(find.byKey(Key('categoryPill_$category')));
    await tester.pumpAndSettle();
  }

  ErrorGuideItem entry(String code) =>
      kErrorGuideCatalog.firstWhere((item) => item.code == code);

  Future<void> pumpGuide(WidgetTester tester, {VoidCallback? onOpenEditor}) =>
      pumpScreen(
        tester,
        Scaffold(
          body: ErrorGuideSheet(
            isModal: false,
            controller: controller,
            onOpenEditor: onOpenEditor,
          ),
        ),
      );

  testWidgets('Current issue defaults to a single compact summary', (
    tester,
  ) async {
    controller.recordError('Processing failed', code: 'ERR_PROCESSING');
    await pumpGuide(tester);
    expect(find.byKey(const Key('latestIssueCard')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('latestIssueCard'))).dy,
      lessThan(32),
    );

    expect(find.text(entry('ERR_PROCESSING').title), findsOneWidget);
    expect(find.byKey(const Key('browseErrorCatalog')), findsOneWidget);
    expect(find.byKey(const Key('errorSearchInput')), findsNothing);
    expect(find.byKey(const Key('errorTile_ERR_PROCESSING')), findsNothing);
    expect(find.text(entry('ERR_PROCESSING').cause), findsNothing);
    expect(find.text('JUST ENCOUNTERED'), findsNothing);
    expect(find.text('Troubleshooting'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'View steps shows exact inline guidance without opening catalog',
    (tester) async {
      var returned = false;
      controller.recordError('Processing failed', code: 'ERR_PROCESSING');
      await pumpGuide(tester, onOpenEditor: () => returned = true);
      await tapKey(tester, 'viewLatestSteps');
      final item = entry('ERR_PROCESSING');
      expect(find.text(item.cause), findsOneWidget);
      for (final step in item.steps) {
        expect(find.text(step), findsOneWidget);
      }
      expect(find.text(item.proTip), findsOneWidget);
      expect(find.text(item.title), findsOneWidget);
      expect(find.byKey(const Key('errorSearchInput')), findsNothing);
      expect(find.text('Hide steps'), findsOneWidget);
      await tapKey(tester, 'viewLatestSteps');
      expect(find.text(item.cause), findsNothing);
      expect(find.byKey(const Key('errorSearchInput')), findsNothing);

      await tapKey(tester, 'returnToEditorFromGuide');
      expect(returned, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Browse reveals all nine codes including the current issue', (
    tester,
  ) async {
    controller.recordError('Processing failed', code: 'ERR_PROCESSING');
    await pumpGuide(tester);
    await openCatalog(tester);
    expect(kErrorGuideCatalog, hasLength(9));
    for (final item in kErrorGuideCatalog) {
      expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
      expect(find.text(item.cause), findsNothing);
    }
    for (final item in kErrorGuideCatalog) {
      await tapKey(tester, 'errorSearchInput');
      await tester.enterText(
        find.byKey(const Key('errorSearchInput')),
        item.code,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
      for (final other in kErrorGuideCatalog.where(
        (entry) => entry.code != item.code,
      )) {
        expect(find.byKey(Key('errorTile_${other.code}')), findsNothing);
      }
    }
    await tapKey(tester, 'clearSearchButton');
    await selectCategory(tester, 'Processing');
    expect(find.byKey(const Key('errorTile_ERR_PROCESSING')), findsOneWidget);
    expect(find.byKey(const Key('errorTile_ERR_DATE_FMT')), findsNothing);
    await selectCategory(tester, 'All');
    for (final item in kErrorGuideCatalog) {
      expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('No issue opens browse catalog and all category menu options', (
    tester,
  ) async {
    await pumpGuide(tester);
    expect(find.text('Nothing to troubleshoot yet'), findsOneWidget);
    expect(find.byKey(const Key('errorSearchInput')), findsOneWidget);
    expect(find.byKey(const Key('viewLatestSteps')), findsNothing);
    await tapKey(tester, 'errorCategoryFilter');
    for (final category in [
      'All',
      ...kErrorGuideCatalog.map((item) => item.category).toSet(),
    ]) {
      expect(find.byKey(Key('categoryPill_$category')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('categoryPill_Integrity')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'errorSearchInput');
    await tester.enterText(
      find.byKey(const Key('errorSearchInput')),
      'XYZ_NO_MATCH',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching error codes found'), findsOneWidget);
    await tapKey(tester, 'resetFiltersButton');
    expect(find.text('No matching error codes found'), findsNothing);
    for (final item in kErrorGuideCatalog) {
      expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
    }
  });

  testWidgets('New live error resets query category steps and scroll', (
    tester,
  ) async {
    controller.recordError('Processing failed', code: 'ERR_PROCESSING');
    await pumpGuide(tester);
    await tapKey(tester, 'viewLatestSteps');
    await openCatalog(tester);
    await selectCategory(tester, 'Location');
    await tapKey(tester, 'errorSearchInput');
    await tester.enterText(
      find.byKey(const Key('errorSearchInput')),
      'latitude',
    );
    await tester.pumpAndSettle();
    controller.recordError(
      'Integrity verification mismatch',
      code: 'ERR_MEDIA_INTEGRITY',
    );
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('errorGuideScroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
    expect(find.text(entry('ERR_MEDIA_INTEGRITY').title), findsOneWidget);
    expect(find.text(entry('ERR_MEDIA_INTEGRITY').cause), findsNothing);
    expect(find.text(entry('ERR_PROCESSING').cause), findsNothing);
    expect(find.byKey(const Key('errorSearchInput')), findsNothing);
    await openCatalog(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('errorSearchInput')))
          .controller!
          .text,
      isEmpty,
    );
    for (final item in kErrorGuideCatalog) {
      expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
    }
  });

  testWidgets(
    'Clearing history resets browser and persists without clearing operation error',
    (tester) async {
      controller.error = 'Operation still failed';
      controller.recordError(controller.error!, code: 'ERR_PROCESSING');
      await pumpGuide(tester);
      await tapKey(tester, 'viewLatestSteps');
      await openCatalog(tester);
      await tapKey(tester, 'errorSearchInput');
      await tester.enterText(
        find.byKey(const Key('errorSearchInput')),
        'processing',
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'clearGuideHistory');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(controller.lastErrorCode, isNull);
      expect(controller.error, 'Operation still failed');
      expect(bridge.editorState.containsKey('lastErrorCode'), isFalse);
      expect(bridge.editorState.containsKey('lastErrorMessage'), isFalse);
      expect(find.text('Nothing to troubleshoot yet'), findsOneWidget);
      expect(find.text(entry('ERR_PROCESSING').cause), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('errorSearchInput')))
            .controller!
            .text,
        isEmpty,
      );
      for (final item in kErrorGuideCatalog) {
        expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
      }
    },
  );

  testWidgets(
    'Unknown current code has safe guidance and browsable reference',
    (tester) async {
      controller.recordError('Unknown stage', code: 'ERR_UNKNOWN_TEST');
      await pumpGuide(tester, onOpenEditor: () {});
      expect(find.textContaining('ERR_UNKNOWN_TEST'), findsOneWidget);
      expect(
        find.textContaining('This code has no catalog entry'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('viewLatestSteps')), findsNothing);
      expect(find.byKey(const Key('returnToEditorFromGuide')), findsOneWidget);
      await openCatalog(tester);
      for (final item in kErrorGuideCatalog) {
        expect(find.byKey(Key('errorTile_${item.code}')), findsOneWidget);
      }
    },
  );

  testWidgets('Startup retry survives cleared history and remains busy gated', (
    tester,
  ) async {
    controller.capabilities = null;
    controller.recordError('Startup failed');
    controller.clearLastError();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    controller.operation = EditorOperation.loading;
    await pumpGuide(tester);
    expect(find.text('Startup required'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('retryStartupFromGuide')))
          .onPressed,
      isNull,
    );
    controller.operation = null;
    controller.recordError('Startup failed');
    await tester.pumpAndSettle();
    await tapKey(tester, 'retryStartupFromGuide');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(controller.ready, isTrue);
    expect(find.byKey(const Key('retryStartupFromGuide')), findsNothing);
  });

  testWidgets('Updated highlighted code resets a reused standalone guide', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const Scaffold(
        body: ErrorGuideSheet(isModal: false, highlightedCode: 'ERR_DATE_FMT'),
      ),
    );
    await tapKey(tester, 'viewLatestSteps');
    final previousState = tester.state(find.byType(ErrorGuideSheet));
    await pumpScreen(
      tester,
      const Scaffold(
        body: ErrorGuideSheet(
          isModal: false,
          highlightedCode: 'ERR_PROCESSING',
        ),
      ),
    );
    expect(tester.state(find.byType(ErrorGuideSheet)), same(previousState));

    expect(find.text(entry('ERR_PROCESSING').title), findsOneWidget);
    expect(find.text(entry('ERR_DATE_FMT').cause), findsNothing);
    expect(find.byKey(const Key('errorSearchInput')), findsNothing);
    await tapKey(tester, 'viewLatestSteps');
    expect(find.text(entry('ERR_PROCESSING').cause), findsOneWidget);
  });

  testWidgets(
    'Modal live history overrides opening highlight and close stays fixed after steps',
    (tester) async {
      controller.recordError('Invalid GPS', code: 'ERR_GPS_BOUNDS');
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
      controller.recordError('Processing failed', code: 'ERR_PROCESSING');
      await tester.pumpAndSettle();
      expect(find.text(entry('ERR_PROCESSING').title), findsOneWidget);
      expect(find.textContaining('ERR_GPS_BOUNDS'), findsNothing);
      await tapKey(tester, 'viewLatestSteps');
      expect(find.text(entry('ERR_PROCESSING').cause), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('errorGuideScroll')),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('closeErrorGuideButton')).hitTestable(),
        findsOneWidget,
      );
      controller.clearLastError();
      await tester.pumpAndSettle();
      expect(find.text(entry('ERR_PROCESSING').cause), findsNothing);
      expect(find.byKey(const Key('errorSearchInput')), findsOneWidget);
      await tester.tap(find.byKey(const Key('closeErrorGuideButton')));
      await tester.pumpAndSettle();
      expect(find.text('Open guide'), findsOneWidget);
      expect(find.byKey(const Key('closeErrorGuideButton')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Guide fits 320px at text scale $scale with keyboard and inline steps',
      (tester) async {
        controller.recordError(
          'Integrity mismatch',
          code: 'ERR_MEDIA_INTEGRITY',
        );
        await pumpScreen(
          tester,
          Scaffold(
            body: ErrorGuideSheet(isModal: false, controller: controller),
          ),
          width: 320,
          scale: scale,
          keyboard: 280,
        );
        await tapKey(tester, 'viewLatestSteps');
        final layoutError = tester.takeException();
        expect(
          layoutError,
          isNull,
          reason: layoutError is FlutterError
              ? layoutError.diagnostics
                    .map((node) => node.toStringDeep())
                    .join('\n')
              : null,
        );
        await openCatalog(tester);
        await tapKey(tester, 'errorSearchInput');
        await tester.enterText(
          find.byKey(const Key('errorSearchInput')),
          'no matching code',
        );
        await tester.pumpAndSettle();
        expect(find.text('No matching error codes found'), findsOneWidget);
        await tapKey(tester, 'resetFiltersButton');
        await selectCategory(tester, 'Processing');
        expect(
          find.byKey(const Key('errorTile_ERR_PROCESSING')),
          findsOneWidget,
        );
        final catalogError = tester.takeException();
        expect(
          catalogError,
          isNull,
          reason: catalogError is FlutterError
              ? catalogError.diagnostics
                    .map((node) => node.toStringDeep())
                    .join('\n')
              : null,
        );
      },
    );
  }

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
  }

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
