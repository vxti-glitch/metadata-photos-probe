import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/metadata_form.dart';
import 'package:metadata_editor/metadata_patch.dart';
import 'package:metadata_editor/media_models.dart';

import 'fake_media_bridge.dart';

class _DelayedStartupBridge extends FakeMediaBridge {
  final startup = Completer<void>();
  @override
  Future<MediaCapabilities> capabilities() async {
    await startup.future;
    return super.capabilities();
  }
}

void main() {
  Future<EditorController> launch(
    WidgetTester tester, {
    FakeMediaBridge? bridge,
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(loadCameraProfiles);
    final controller = EditorController(bridge ?? FakeMediaBridge());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MetadataEditorApp(controller: controller));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 180);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('home and navigation fit a narrow phone at large text', (
    tester,
  ) async {
    await launch(tester, scale: 2);
    expect(find.byKey(const Key('selectMedia')), findsOneWidget);
    expect(find.byKey(const Key('homeBrandHeader')), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded).hitTestable(), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    final header = tester.getRect(find.byKey(const Key('homeBrandHeader')));
    final settings = tester.getRect(find.byKey(const Key('openSettings')));
    expect(header.top, lessThan(30));
    expect(settings.width, greaterThanOrEqualTo(44));
    expect(settings.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('tabErrorCodes')), findsNothing);
    expect(find.byKey(const Key('openErrorGuideFromBar')), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    await tap(tester, 'openSettings');
    await tap(tester, 'errorGuideRow');
    expect(find.text('Error Codes & Fixes'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tap(tester, 'errorGuideBackButton');
    expect(find.text('Settings'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tap(tester, 'settingsBackButton');
    expect(find.byKey(const Key('selectMedia')), findsOneWidget);
  });

  testWidgets(
    'Home respects the status area and selects readable status icons',
    (tester) async {
      tester.view.padding = FakeViewPadding(top: 59);
      tester.view.viewPadding = FakeViewPadding(top: 59);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final controller = await launch(tester);
      for (final appearance in ['dark', 'light']) {
        await controller.setAppearance(appearance);
        await tester.pumpAndSettle();
        final header = tester.getRect(find.byKey(const Key('homeBrandHeader')));
        expect(header.top, greaterThanOrEqualTo(59));
        final settings = tester.getRect(find.byKey(const Key('openSettings')));
        expect(settings.size, const Size(48, 48));
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find
              .ancestor(
                of: find.byKey(const Key('homeGlow')),
                matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
              )
              .first,
        );
        expect(
          region.value.statusBarIconBrightness,
          appearance == 'dark' ? Brightness.light : Brightness.dark,
        );
        expect(
          region.value.statusBarBrightness,
          appearance == 'dark' ? Brightness.dark : Brightness.light,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'Home tint follows appearance and stays off Settings and editing',
    (tester) async {
      final controller = await launch(tester);
      for (final appearance in ['dark', 'light']) {
        await controller.setAppearance(appearance);
        await tester.pumpAndSettle();
        final glow = tester.widget<DecoratedBox>(
          find.byKey(const Key('homeGlow')),
        );
        final gradient =
            (glow.decoration as BoxDecoration).gradient! as LinearGradient;
        expect(
          gradient.colors.first,
          appearance == 'dark'
              ? const Color(0xFF545454)
              : const Color(0xFFCFCFCF),
        );
        await tap(tester, 'openSettings');
        expect(find.byKey(const Key('homeGlow')).hitTestable(), findsNothing);
        expect(
          find.byKey(const Key('settingsBackButton')).hitTestable(),
          findsOneWidget,
        );
        await tap(tester, 'settingsBackButton');
        expect(find.byKey(const Key('homeGlow')), findsOneWidget);
      }
      await tap(tester, 'selectMedia');
      await tap(tester, 'importFiles');
      expect(find.byKey(const Key('homeGlow')), findsNothing);
      expect(find.byKey(const Key('backToHome')), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded).hitTestable(), findsOneWidget);
      await tap(tester, 'backToHome');
      expect(find.byKey(const Key('homeGlow')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Settings remain available during startup, failure and retry', (
    tester,
  ) async {
    final bridge = _DelayedStartupBridge()
      ..startupError = StateError('Engine unavailable');
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MetadataEditorApp(controller: controller));
    await tester.pump();
    expect(controller.ready, isFalse);
    expect(find.byKey(const Key('openSettings')).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pump();
    expect(find.byKey(const Key('errorGuideRow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settingsBackButton')));
    await tester.pump();
    bridge.startup.complete();
    await tester.pumpAndSettle();
    expect(controller.ready, isFalse);
    expect(find.byKey(const Key('selectMedia')), findsNothing);
    await tap(tester, 'openSettings');
    await tap(tester, 'errorGuideRow');
    await tap(tester, 'errorGuideBackButton');
    await tap(tester, 'settingsBackButton');
    await tester.tap(find.text('Retry startup'));
    await tester.pumpAndSettle();
    expect(controller.ready, isFalse);
    await tap(tester, 'openSettings');
    await tap(tester, 'settingsBackButton');
    bridge.startupError = null;
    await tester.tap(find.text('Retry startup'));
    await tester.pumpAndSettle();
    expect(controller.ready, isTrue);
    expect(find.byKey(const Key('selectMedia')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing draft survives nested guide back and return to editor', (
    tester,
  ) async {
    final bridge = FakeMediaBridge();
    final controller = await launch(tester, bridge: bridge);
    await tap(tester, 'selectMedia');
    await tap(tester, 'importFiles');
    await tap(tester, 'manualEditing');
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
    controller.recordError('Latitude must be between -90 and 90');
    await tester.pumpAndSettle();
    await tap(tester, 'openSettings');
    await tap(tester, 'errorGuideRow');
    await tap(tester, 'viewLatestSteps');
    await tap(tester, 'errorGuideBackButton');
    expect(find.text('Settings'), findsWidgets);
    await tap(tester, 'errorGuideRow');
    await tap(tester, 'returnToEditorFromGuide');
    expect(find.byKey(const Key('errorGuideBackButton')), findsNothing);
    expect(find.byKey(const Key('backToHome')), findsOneWidget);
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
    expect(find.text('Error Codes & Fixes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error message is compact with optional details and dismissal', (
    tester,
  ) async {
    final controller = await launch(tester);
    await controller.setAppearance('dark');
    controller.error = 'The edited copy failed media preservation checks. No new output is available.';
    controller.recordError(controller.error!, code: 'ERR_MEDIA_INTEGRITY');
    await tester.pumpAndSettle();
    final banner = find.byKey(const Key('diagnosticErrorBanner'));
    expect(tester.getSize(banner).height, lessThan(130));
    expect(find.text('ERR_MEDIA_INTEGRITY'), findsNothing);
    expect(find.text('Attention Needed'), findsNothing);
    expect(find.text('Error details'), findsNothing);
    expect(find.text('Details'), findsOneWidget);
    await tap(tester, 'viewSolutionButton');
    expect(find.text('Error Codes & Fixes'), findsOneWidget);
    expect(find.text('Media or Metadata Integrity Check Failed'), findsWidgets);
    await tap(tester, 'errorGuideBackButton');
    await tap(tester, 'settingsBackButton');
    await tap(tester, 'dismissErrorBannerButton');
    expect(banner, findsNothing);
    expect(controller.lastErrorCode, 'ERR_MEDIA_INTEGRITY');
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear confirmation preserves published copies', (tester) async {
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    await launch(tester, bridge: bridge);
    await tap(tester, 'openSettings');
    await tap(tester, 'localProjectsRow');
    await tap(tester, 'clearCacheButton');
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Photos originals'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('already exported copies remain unchanged'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
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
  testWidgets(
    'selection picker is a single entry point and cancel leaves Home',
    (tester) async {
      final bridge = FakeMediaBridge();
      await launch(tester, bridge: bridge);
      expect(find.byKey(const Key('importFiles')), findsNothing);
      expect(find.byKey(const Key('importPhotos')), findsNothing);
      await tap(tester, 'selectMedia');
      expect(find.byKey(const Key('importFiles')), findsOneWidget);
      expect(find.byKey(const Key('importPhotos')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const Key('importFiles')))).pop();
      await tester.pumpAndSettle();
      expect(bridge.imports, 0);
      expect(find.byKey(const Key('selectMedia')), findsOneWidget);
    },
  );

  testWidgets(
    'multiple imported items enter batch and Home back clears all selection',
    (tester) async {
      final bridge = FakeMediaBridge()
        ..batchImportResult = [fixture(), fixture(id: nextOutputId)];
      final controller = await launch(tester, bridge: bridge);
      await tap(tester, 'selectMedia');
      await tap(tester, 'importFiles');
      expect(controller.batchSelection, hasLength(2));
      expect(controller.isBatchMode, isTrue);
      expect(
        tester.widget<MetadataForm>(find.byType(MetadataForm)).batch,
        isTrue,
      );
      await tap(tester, 'backToHome');
      expect(controller.selected, isNull);
      expect(controller.isBatchMode, isFalse);
      expect(controller.batchSelection, isEmpty);
      expect(controller.sessions, hasLength(2));
      expect(bridge.clears, 0);
      expect(bridge.deletedIds, isEmpty);
      expect(find.byKey(const Key('selectMedia')), findsOneWidget);
    },
  );

  testWidgets('appearance changes preserve exact editor state and selection', (
    tester,
  ) async {
    final controller = await launch(tester);
    await tap(tester, 'selectMedia');
    await tap(tester, 'importFiles');
    final formState = tester.state(find.byType(MetadataForm));
    final selected = controller.selected;
    await controller.setAppearance('light');
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(MetadataForm))).brightness,
      Brightness.light,
    );
    expect(tester.state(find.byType(MetadataForm)), same(formState));
    expect(controller.selected, same(selected));
    await tap(tester, 'openSettings');
    await controller.setAppearance('dark');
    await tester.pumpAndSettle();
    await tap(tester, 'settingsBackButton');
    expect(
      Theme.of(tester.element(find.byType(MetadataForm))).brightness,
      Brightness.dark,
    );
    expect(tester.state(find.byType(MetadataForm)), same(formState));
    expect(controller.selected, same(selected));
    expect(tester.takeException(), isNull);
  });

  testWidgets('system appearance follows platform changes on Home', (
    tester,
  ) async {
    await launch(tester);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const Key('selectMedia')))).brightness,
      Brightness.light,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byKey(const Key('selectMedia')))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  for (final sameSelection in [false, true]) {
    testWidgets(
      'resume stored batch resets mounted ${sameSelection ? 'same' : 'different'} review',
      (tester) async {
        const otherId = '00000000-0000-4000-8000-000000000004';
        const fourthId = '00000000-0000-4000-8000-000000000005';
        final bridge = FakeMediaBridge()
          ..sessions = [
            fixture(),
            fixture(id: nextOutputId),
            fixture(id: otherId),
            fixture(id: fourthId),
          ]
          ..processError = const FormatException('Temporary write failure.');
        final controller = await launch(tester, bridge: bridge);
        controller.batchSelection.addAll([sourceId, nextOutputId]);
        controller.startBatchEditing();
        await controller.processBatch({
          sourceId: MetadataPatch(values: {'make': 'Apple'}),
          nextOutputId: MetadataPatch(values: {'make': 'Apple'}),
        });
        await tester.pumpAndSettle();
        bridge.processError = null;
        if (sameSelection) {
          await tap(tester, 'primaryresultAction');
        } else {
          controller.batchSelection
            ..clear()
            ..addAll([otherId, fourthId]);
          controller.startBatchEditing();
          await tester.pumpAndSettle();
        }
        await tap(tester, 'primaryeditAction');
        final priorState = tester.state(find.byType(MetadataForm));
        expect(find.byKey(const Key('primaryreviewAction')), findsOneWidget);
        await tap(tester, 'openSettings');
        await tap(tester, 'localProjectsRow');
        await tap(tester, 'resumeStoredBatch');
        expect(controller.batchSelection, {sourceId, nextOutputId});
        expect(
          tester.state(find.byType(MetadataForm)),
          isNot(same(priorState)),
        );
        expect(find.byKey(const Key('primaryreviewAction')), findsNothing);
        expect(find.byKey(const Key('retryUnfinishedBatch')), findsOneWidget);
        expect(bridge.processes, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
