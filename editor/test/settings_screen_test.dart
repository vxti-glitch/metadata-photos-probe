import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_brand.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/metadata_patch.dart';
import 'package:metadata_editor/settings_screen.dart';

import 'fake_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeMediaBridge bridge;
  late EditorController controller;

  setUp(() async {
    bridge = FakeMediaBridge();
    controller = EditorController(bridge);
    await controller.initialize();
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'AppBar contains settings button that navigates to SettingsScreen',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(home: MetadataEditorApp(controller: controller)),
      );
      await tester.pumpAndSettle();

      final settingsButton = find.byKey(const Key('openSettings'));
      expect(settingsButton, findsOneWidget);

      await tester.tap(settingsButton);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    },
  );

  testWidgets('App Identity section displays correct branding and version', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.text(AppBrand.name), findsOneWidget);
    expect(find.text('by vxti'), findsOneWidget);
    expect(find.text('Version ${AppBrand.version}'), findsOneWidget);
    expect(find.byType(MetadataMark), findsOneWidget);
  });

  testWidgets(
    'Visit Website row triggers openUrl without displaying URL in row',
    (tester) async {
      await pumpSettings(tester);

      expect(find.text('Visit Website'), findsOneWidget);
      // Explicitly verify the row does not display raw URL string text
      expect(find.text('https://zlarp.com'), findsNothing);
      expect(find.text('zlarp.com'), findsNothing);

      await tester.tap(find.byKey(const Key('visitWebsiteRow')));
      await tester.pumpAndSettle();

      expect(bridge.openedUrls, contains('https://zlarp.com'));
    },
  );

  testWidgets('Privacy Policy row opens legal sheet with readable policy', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('privacyPolicyRow')));
    await tester.pumpAndSettle();

    expect(find.text('Privacy Policy'), findsAtLeastNWidgets(1));
    expect(
      find.textContaining('Privacy Policy — Metadata Editor'),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.textContaining('Zero Cloud Processing'),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.textContaining('read/write authorization on demand'),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.textContaining('cloud-backed original'),
      findsAtLeastNWidgets(1),
    );
    expect(find.textContaining('ProbeCore'), findsAtLeastNWidgets(1));

    // Close the sheet
    await tester.tap(find.byKey(const Key('closeLegalSheetButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Zero Cloud Processing'), findsNothing);
  });

  testWidgets('Terms of Use row opens legal sheet with readable terms', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('termsOfUseRow')));
    await tester.pumpAndSettle();

    expect(find.text('Terms of Use'), findsAtLeastNWidgets(1));
    expect(
      find.textContaining('Terms of Use — Metadata Editor'),
      findsAtLeastNWidgets(1),
    );
    expect(find.textContaining('Acceptance of Terms'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Zlarp'), findsAtLeastNWidgets(1));

    // Close the sheet
    await tester.tap(find.byKey(const Key('closeLegalSheetButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Acceptance of Terms'), findsNothing);
  });

  testWidgets('The Photos Workflow and Preserve Originals show explanations', (
    tester,
  ) async {
    await pumpSettings(tester);

    // The Photos Workflow
    await tester.tap(find.byKey(const Key('photosWorkflowRow')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('To guarantee immutable camera originals'),
      findsOneWidget,
    );
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    // Preserve Source Originals
    await tester.tap(find.byKey(const Key('preserveOriginalsRow')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('source media bit-for-bit identical'),
      findsOneWidget,
    );
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
  });

  testWidgets('Temporary Media Cache confirmation clears cache', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('clearCacheButton')));
    await tester.pumpAndSettle();

    expect(find.text('Clear Media Cache?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirmClearCacheButton')));
    await tester.pumpAndSettle();

    expect(bridge.clears, 1);
  });

  testWidgets('Saved Camera Presets confirmation resets presets', (
    tester,
  ) async {
    // Add a preset first
    await controller.savePreset(
      'Test Preset',
      MetadataPatch(values: {'make': 'Apple', 'model': 'iPhone 15 Pro'}),
    );
    expect(controller.presets.length, 1);

    await pumpSettings(tester);

    expect(find.text('1 custom preset(s) stored locally'), findsOneWidget);

    await tester.tap(find.byKey(const Key('resetPresetsButton')));
    await tester.pumpAndSettle();

    expect(find.text('Reset Saved Presets?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirmResetPresetsButton')));
    await tester.pumpAndSettle();

    expect(controller.presets.isEmpty, isTrue);
    expect(find.text('0 custom preset(s) stored locally'), findsOneWidget);
  });

  testWidgets('Diagnostics and Footer display accurate metadata', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.text('Swift Media Engine'), findsOneWidget);
    expect(
      find.text('ProbeCore v0.4 · Ready · Sandboxed local engine'),
      findsOneWidget,
    );
    expect(find.text('Privacy Guarantee'), findsOneWidget);
    expect(
      find.text(
        'On-device processing · No analytics · Cloud-backed imports may download',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '${AppBrand.name} ${AppBrand.version} (Build ${AppBrand.buildNumber}) · © 2026 ${AppBrand.developer}',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'Help & Troubleshooting section displays Error Codes & Fixes and Photos Attribution Guide',
    (tester) async {
      await pumpSettings(tester);

      expect(find.text('HELP & TROUBLESHOOTING'), findsOneWidget);
      expect(find.text('Error Codes & Fixes'), findsOneWidget);
      expect(find.text('8 CODES'), findsOneWidget);
      expect(find.text('Photos Attribution Guide'), findsOneWidget);
    },
  );

  testWidgets(
    'Photos Attribution Guide row opens explanation dialog with attribution details',
    (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const Key('photosAttributionRow')));
      await tester.pumpAndSettle();

      expect(find.text('Photos Attribution Guide'), findsAtLeastNWidgets(1));
      expect(
        find.textContaining(
          'Why does Photos show "Saved from Metadata Editor"?',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('How to prevent attribution stamps:'),
        findsOneWidget,
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('How to prevent attribution stamps:'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Error Codes & Fixes row opens Error Reference Guide modal sheet with search and filtering',
    (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const Key('errorGuideRow')));
      await tester.pumpAndSettle();

      expect(find.text('Error Reference Guide'), findsOneWidget);
      expect(find.text('8 error codes with diagnostic fixes'), findsOneWidget);
      expect(find.text('ERR_DATE_FMT'), findsOneWidget);
      expect(find.text('ERR_GPS_BOUNDS'), findsOneWidget);

      // Search filtering for 'GPS'
      await tester.enterText(find.byKey(const Key('errorSearchInput')), 'GPS');
      await tester.pumpAndSettle();

      expect(find.text('ERR_GPS_BOUNDS'), findsOneWidget);
      expect(find.text('ERR_DATE_FMT'), findsNothing);

      // Clear search
      await tester.tap(find.byKey(const Key('clearSearchButton')));
      await tester.pumpAndSettle();
      expect(find.text('ERR_DATE_FMT'), findsOneWidget);

      // Category filter for 'Integrity'
      await tester.tap(find.byKey(const Key('categoryPill_Integrity')));
      await tester.pumpAndSettle();

      expect(find.text('ERR_MEDIA_INTEGRITY'), findsOneWidget);
      expect(find.text('ERR_GPS_BOUNDS'), findsNothing);

      // Reset category filter to 'All'
      await tester.tap(find.byKey(const Key('categoryPill_All')));
      await tester.pumpAndSettle();

      // Expand ERR_GPS_BOUNDS
      await tester.tap(find.byKey(const Key('errorTile_ERR_GPS_BOUNDS')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Geographic coordinates must fall within standard physical boundaries',
        ),
        findsOneWidget,
      );
      expect(find.text('WHY THIS HAPPENS'), findsAtLeastNWidgets(1));
      // Zero-match search query test
      await tester.enterText(
        find.byKey(const Key('errorSearchInput')),
        'XYZ_NO_MATCH_CODE',
      );
      await tester.pumpAndSettle();

      expect(find.text('No matching error codes found'), findsOneWidget);
      expect(find.byKey(const Key('resetFiltersButton')), findsOneWidget);

      // Tap Reset Filters
      await tester.tap(find.byKey(const Key('resetFiltersButton')));
      await tester.pumpAndSettle();

      expect(find.text('No matching error codes found'), findsNothing);
      expect(find.text('ERR_DATE_FMT'), findsOneWidget);

      // Close sheet
      await tester.tap(find.byKey(const Key('closeErrorGuideButton')));
      await tester.pumpAndSettle();

      expect(find.text('Error Reference Guide'), findsNothing);
    },
  );

  testWidgets(
    'Recent Error Detected banner displays when lastErrorCode is set, and dismiss button clears it',
    (tester) async {
      controller.recordError(
        'Native metadata processing or independent integrity verification failed',
      );
      await pumpSettings(tester);

      expect(find.text('RECENT ERROR DETECTED'), findsOneWidget);
      expect(find.byKey(const Key('recentErrorBanner')), findsOneWidget);
      expect(find.byKey(const Key('recentErrorCodeBadge')), findsOneWidget);
      expect(find.text('ERR_MEDIA_INTEGRITY'), findsOneWidget);
      expect(find.text('ACTIVE FIX AVAILABLE'), findsOneWidget);
      expect(find.text('ACTIVE FIX'), findsOneWidget);
      expect(find.byKey(const Key('dismissRecentErrorButton')), findsOneWidget);

      // Tap dismiss button
      await tester.tap(find.byKey(const Key('dismissRecentErrorButton')));
      await tester.pumpAndSettle();

      expect(find.text('RECENT ERROR DETECTED'), findsNothing);
      expect(find.byKey(const Key('recentErrorBanner')), findsNothing);
      expect(find.text('8 CODES'), findsOneWidget);
      expect(controller.lastErrorCode, isNull);
    },
  );

  testWidgets(
    'View Recent Error Fix button opens Error Guide with promoted and auto-expanded card',
    (tester) async {
      controller.recordError('Latitude must be between -90 and 90');
      await pumpSettings(tester);

      expect(find.text('ERR_GPS_BOUNDS'), findsOneWidget);

      await tester.tap(find.byKey(const Key('viewRecentErrorFixButton')));
      await tester.pumpAndSettle();

      expect(find.text('Error Reference Guide'), findsOneWidget);
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_GPS_BOUNDS')),
        findsOneWidget,
      );
      expect(find.text('JUST ENCOUNTERED'), findsOneWidget);
      expect(
        find.textContaining(
          'Geographic coordinates must fall within standard physical boundaries',
        ),
        findsOneWidget,
      );

      // Close sheet
      await tester.tap(find.byKey(const Key('closeErrorGuideButton')));
      await tester.pumpAndSettle();

      expect(find.text('Error Reference Guide'), findsNothing);
    },
  );

  testWidgets(
    'System Health card displays Photos Access, Swift Media Engine, and Storage Sandbox live status',
    (tester) async {
      await pumpSettings(tester);

      expect(find.text('SYSTEM HEALTH & DIAGNOSTICS'), findsOneWidget);
      expect(find.text('Photos Access'), findsOneWidget);
      expect(find.text('ON IMPORT'), findsOneWidget);
      expect(find.text('Swift Media Engine'), findsOneWidget);
      expect(find.textContaining('· Ready ·'), findsOneWidget);
      expect(find.text('Storage Sandbox'), findsOneWidget);
      expect(find.text('FILE-BACKED'), findsOneWidget);
      expect(find.text('Privacy Guarantee'), findsOneWidget);
    },
  );

  testWidgets(
    'System Health does not claim the engine is ready without capabilities',
    (tester) async {
      controller.capabilities = null;
      await pumpSettings(tester);

      expect(find.text('ON IMPORT'), findsOneWidget);
      expect(find.textContaining('· Not ready ·'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    },
  );

  testWidgets(
    'Main navigation bar switches between Editor, Error Codes, and Settings tabs',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(home: MetadataEditorApp(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mainNavigationBar')), findsOneWidget);
      expect(find.byKey(const Key('tabEditor')), findsOneWidget);
      expect(find.byKey(const Key('tabErrorCodes')), findsOneWidget);
      expect(find.byKey(const Key('tabSettings')), findsOneWidget);

      // Tap Error Codes tab
      await tester.tap(find.byKey(const Key('tabErrorCodes')));
      await tester.pumpAndSettle();

      expect(find.text('ERROR CODES & FIXES'), findsOneWidget);
      expect(find.text('Error Reference Guide'), findsOneWidget);
      expect(find.text('8 error codes with diagnostic fixes'), findsOneWidget);

      // Tap Settings tab
      await tester.tap(find.byKey(const Key('tabSettings')));
      await tester.pumpAndSettle();

      expect(find.text('SYSTEM HEALTH & DIAGNOSTICS'), findsOneWidget);

      // Tap Editor tab
      await tester.tap(find.byKey(const Key('tabEditor')));
      await tester.pumpAndSettle();

      expect(find.text('LOCAL PROJECTS'), findsOneWidget);
    },
  );

  testWidgets(
    'DiagnosticErrorBanner displays simplified text, error code pill, and View Solution switches to Error Codes tab',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(home: MetadataEditorApp(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Trigger an integrity error
      controller.error =
          'Integrity verification mismatch: retained embedded metadata';
      controller.recordError(controller.error!);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('diagnosticErrorBanner')), findsOneWidget);
      expect(find.text('ERR_MEDIA_INTEGRITY'), findsOneWidget);
      expect(find.text('Attention Needed'), findsOneWidget);
      expect(
        find.textContaining('could not confirm that the media'),
        findsOneWidget,
      );

      // Tap View Solution & Steps
      await tester.tap(find.byKey(const Key('viewSolutionButton')));
      await tester.pumpAndSettle();

      // Should have switched to Error Codes tab
      expect(find.text('ERROR CODES & FIXES'), findsOneWidget);
      expect(find.text('ERR_MEDIA_INTEGRITY'), findsWidgets);
      expect(
        find.byKey(const Key('justEncounteredBadge_ERR_MEDIA_INTEGRITY')),
        findsOneWidget,
      );
      expect(find.text('JUST ENCOUNTERED'), findsOneWidget);

      // Switch back to Editor and dismiss banner
      await tester.tap(find.byKey(const Key('tabEditor')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('diagnosticErrorBanner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dismissErrorBannerButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('diagnosticErrorBanner')), findsNothing);
    },
  );
}
