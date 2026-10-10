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
    expect(find.text('Version 1.0'), findsOneWidget);
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
      find.text('ProbeCore v0.4 · Sandboxed local engine'),
      findsOneWidget,
    );
    expect(find.text('Privacy Guarantee'), findsOneWidget);
    expect(
      find.text('100% on-device · Zero analytics · No cloud pings'),
      findsOneWidget,
    );
    expect(
      find.text('Metadata Editor 1.0 (Build 6) · © 2026 vxti'),
      findsOneWidget,
    );
  });
}
