import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_brand.dart';
import 'package:metadata_editor/app_theme.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/legal_documents.dart';
import 'package:metadata_editor/metadata_patch.dart';
import 'package:metadata_editor/settings_destinations.dart';
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
  tearDown(() => controller.dispose());

  Future<void> pumpSettings(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
    double scale = 1,
    VoidCallback? onOpenEditor,
  }) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.light
            ? AppTheme.lightTheme()
            : AppTheme.darkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SettingsScreen(
          controller: controller,
          onOpenEditor: onOpenEditor,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(Key(key));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Settings displays current logo, name, developer and version without a flame',
    (tester) async {
      await pumpSettings(tester);
      expect(find.text(AppBrand.name), findsOneWidget);
      expect(find.text('by vxti'), findsOneWidget);
      expect(find.text('Version ${AppBrand.version}'), findsOneWidget);
      expect(find.byType(MetadataMark), findsOneWidget);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
      expect(find.byKey(const Key('appearanceRow')), findsOneWidget);
      expect(find.byKey(const Key('localProjectsRow')), findsOneWidget);
      expect(find.byKey(const Key('savedPresetsRow')), findsOneWidget);
    },
  );

  testWidgets('Contact support is a normal row and opens email directly', (
    tester,
  ) async {
    await pumpSettings(tester);
    final row = find.byKey(const Key('contactSupportRow'));
    await tester.ensureVisible(row);
    expect(find.text('Contact support'), findsOneWidget);
    expect(find.text(AppBrand.supportEmail), findsNothing);
    expect(tester.getSize(row).height, lessThan(80));
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(bridge.supportEmailOpens, 1);
    expect(bridge.openedUrls, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      controller.notice,
      'Continue in your email app to send your message.',
    );
  });

  testWidgets('Support works without engine readiness', (tester) async {
    controller.capabilities = null;
    await pumpSettings(tester);
    await tapKey(tester, 'contactSupportRow');
    expect(bridge.supportEmailOpens, 1);
    expect(controller.ready, isFalse);
  });

  testWidgets(
    'Support blocks repeat launches and cancellation during handoff',
    (tester) async {
      bridge.supportEmailCompletion = Completer<void>();
      await pumpSettings(tester);
      final row = find.byKey(const Key('contactSupportRow'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      expect(controller.operation, EditorOperation.openingEmail);
      expect(tester.widget<SettingsItem>(row).onTap, isNull);
      await controller.openSupportEmail();
      await controller.cancel();
      expect(bridge.supportEmailOpens, 1);
      expect(controller.cancellationRequested, isFalse);
      bridge.supportEmailCompletion!.complete();
      await tester.pumpAndSettle();
      expect(controller.busy, isFalse);
    },
  );

  testWidgets(
    'Failed email handoff is actionable and preserves selected drafts',
    (tester) async {
      const message =
          'No email app could open. Install or configure an email app, then try again, or email vxti.dev@gmail.com with the subject Metadata Editor Support.';
      bridge.supportEmailFailure = PlatformException(
        code: 'email_unavailable',
        message: message,
      );
      final source = fixture();
      controller.selected = source;
      controller.batchSelection.add(source.id);
      await pumpSettings(tester);
      await tapKey(tester, 'contactSupportRow');
      expect(controller.error, message);
      expect(find.text(message), findsOneWidget);
      expect(controller.busy, isFalse);
      expect(controller.selected, same(source));
      expect(controller.batchSelection, contains(source.id));
    },
  );

  testWidgets('Website row opens external URL without displaying raw address', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tapKey(tester, 'visitWebsiteRow');
    expect(bridge.openedUrls, [AppBrand.websiteUrl]);
    expect(find.text(AppBrand.websiteUrl), findsNothing);
  });

  for (final entry in [
    ('privacyPolicyRow', 'Privacy Policy', LegalDocuments.privacyPolicy),
    ('termsOfUseRow', 'Terms of Use', LegalDocuments.termsOfUse),
  ]) {
    testWidgets('${entry.$2} opens unchanged readable legal text', (
      tester,
    ) async {
      await pumpSettings(tester);
      await tapKey(tester, entry.$1);
      expect(find.text(entry.$3), findsOneWidget);
      expect(find.text(entry.$2), findsWidgets);
      await tapKey(tester, 'closeLegalSheetButton');
      expect(find.text(entry.$3), findsNothing);
    });
  }

  testWidgets('Appearance is a separate System Light Dark selector', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tapKey(tester, 'appearanceRow');
    expect(find.text('Appearance'), findsOneWidget);
    for (final choice in ['system', 'light', 'dark']) {
      expect(find.byKey(Key('appearance_$choice')), findsOneWidget);
    }
    await tapKey(tester, 'appearance_light');
    expect(controller.appearance, 'light');
    expect(bridge.editorState['appearance'], 'light');
    await tapKey(tester, 'settingsDestinationBack');
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
  });

  testWidgets(
    'Local projects selects an existing file and returns to the preserved editor',
    (tester) async {
      bridge.sessions = [fixture()];
      await controller.initialize();
      var opened = false;
      await pumpSettings(tester, onOpenEditor: () => opened = true);
      await tapKey(tester, 'localProjectsRow');
      await tapKey(tester, 'localProject_$sourceId');
      expect(controller.selected?.id, sourceId);
      expect(opened, isTrue);
      expect(find.text('Settings'), findsOneWidget);
    },
  );

  testWidgets(
    'Local project deletion asks confirmation before deleting only the chosen project',
    (tester) async {
      bridge.sessions = [fixture(), fixture(id: nextOutputId)];
      await controller.initialize();
      await pumpSettings(tester);
      await tapKey(tester, 'localProjectsRow');
      await tapKey(tester, 'deleteLocalProject_$sourceId');
      expect(find.text('Delete Local Project?'), findsOneWidget);
      expect(bridge.deletedIds, isEmpty);
      await tester.tap(find.text('Delete project'));
      await tester.pumpAndSettle();
      expect(bridge.deletedIds, [sourceId]);
      expect(controller.sessions.single.id, nextOutputId);
    },
  );

  testWidgets(
    'Clear local projects has its own confirmation and preserves export explanation',
    (tester) async {
      bridge.sessions = [fixture()];
      await controller.initialize();
      await pumpSettings(tester);
      await tapKey(tester, 'localProjectsRow');
      await tapKey(tester, 'clearCacheButton');
      expect(find.text('Clear Local Projects?'), findsOneWidget);
      expect(
        find.textContaining('already exported copies remain unchanged'),
        findsOneWidget,
      );
      expect(bridge.clears, 0);
      await tapKey(tester, 'confirmClearCacheButton');
      expect(bridge.clears, 1);
      expect(find.text('No local projects'), findsOneWidget);
    },
  );

  testWidgets(
    'Presets page supports import and existing preset export and delete',
    (tester) async {
      await tester.runAsync(
        () => controller.savePreset(
          'Camera recipe',
          MetadataPatch(values: {'make': 'Apple', 'model': 'iPhone 15 Pro'}),
        ),
      );
      final preset = controller.presets.single;
      await pumpSettings(tester);
      await tapKey(tester, 'savedPresetsRow');
      await tapKey(tester, 'importPresetFromSettings');
      expect(bridge.presetImports, 1);
      await tapKey(tester, 'settingsPresetMenu_${preset.id}');
      await tester.tap(find.text('Export to Files'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(bridge.presetExports, 1);
      expect(bridge.exportedPreset, preset.toMap());
      await tapKey(tester, 'settingsPresetMenu_${preset.id}');
      await tester.tap(find.text('Delete preset'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Preset?'), findsOneWidget);
      expect(controller.presets, hasLength(1));
      await tester.tap(find.text('Delete preset').last);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(controller.presets, isEmpty);
      expect(find.text('No saved presets'), findsOneWidget);
    },
  );

  testWidgets('Reset saved presets requires confirmation', (tester) async {
    await tester.runAsync(
      () => controller.savePreset(
        'Saved',
        MetadataPatch(values: {'make': 'Apple'}),
      ),
    );
    await pumpSettings(tester);
    await tapKey(tester, 'savedPresetsRow');
    await tapKey(tester, 'resetPresetsButton');
    expect(find.text('Reset Saved Presets?'), findsOneWidget);
    expect(controller.presets, hasLength(1));
    await tapKey(tester, 'confirmResetPresetsButton');
    expect(controller.presets, isEmpty);
  });

  testWidgets(
    'Photos guide explains the complete manual workflow and attribution limits',
    (tester) async {
      await pumpSettings(tester);
      await tapKey(tester, 'photosAttributionRow');
      for (final title in [
        '1. Create an edited copy',
        '2. Export to Files',
        '3. Upload through Safari',
        '4. Wait for Photos to sync',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(
        find.textContaining(
          'Embedded metadata and Photos app-origin labels are separate',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Apple controls the resulting Photos presentation'),
        findsOneWidget,
      );
      await tapKey(tester, 'openICloudFromSettings');
      expect(bridge.opens, 1);
    },
  );

  testWidgets(
    'Media export page describes actual capabilities, immutable originals and incomplete verification',
    (tester) async {
      await pumpSettings(tester);
      await tapKey(tester, 'mediaExportDetails');
      expect(
        find.textContaining('JPEG · HEIC · PNG · MP4 · MOV'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Source media remains bit-for-bit identical'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Changes to other file details show a warning and allow export',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Failed media or requested-edit checks block export',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Limited checks still require your acknowledgment'),
        findsOneWidget,
      );
      expect(find.textContaining('Live Photos are outside'), findsOneWidget);
    },
  );

  testWidgets('Media formats are not claimed while the engine is unready', (
    tester,
  ) async {
    controller.capabilities = null;
    await pumpSettings(tester);
    await tapKey(tester, 'mediaExportDetails');
    expect(
      find.text('Format support is available after startup.'),
      findsOneWidget,
    );
    expect(find.textContaining('JPEG · HEIC · PNG · MP4 · MOV'), findsNothing);
  });

  testWidgets('Diagnostics shows accurate status and can retry startup', (
    tester,
  ) async {
    controller.capabilities = null;
    await pumpSettings(tester);
    await tapKey(tester, 'engineDetails');
    expect(find.text('ON IMPORT'), findsOneWidget);
    expect(find.text('FILE-BACKED'), findsOneWidget);
    expect(find.textContaining('· Not ready ·'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    await tapKey(tester, 'retryStartupFromSettings');
    expect(controller.ready, isTrue);
    expect(find.textContaining('· Ready ·'), findsOneWidget);
    expect(find.text('Privacy Guarantee'), findsOneWidget);
    expect(
      find.textContaining('On-device processing · No analytics'),
      findsOneWidget,
    );
  });

  testWidgets('App information exposes exact current build identity', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tapKey(tester, 'appInformationRow');
    expect(find.text(AppBrand.name), findsOneWidget);
    expect(find.text('by ${AppBrand.developer}'), findsOneWidget);
    expect(
      find.text('${AppBrand.version} · Build ${AppBrand.buildNumber}'),
      findsOneWidget,
    );
    expect(find.text(AppBrand.engineCore), findsOneWidget);
  });

  testWidgets(
    'Settings Error Reference remains a separate page with all codes search and category filters',
    (tester) async {
      await pumpSettings(tester);
      await tapKey(tester, 'errorGuideRow');
      expect(find.byKey(const Key('errorGuideBackButton')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const Key('errorTile_ERR_DATE_FMT')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('errorSearchInput')), 'GPS');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('errorTile_ERR_GPS_BOUNDS')), findsOneWidget);
      expect(find.byKey(const Key('errorTile_ERR_DATE_FMT')), findsNothing);
      await tapKey(tester, 'clearSearchButton');
      await tapKey(tester, 'errorCategoryFilter');
      await tester.tap(find.byKey(const Key('categoryPill_Integrity')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('errorTile_ERR_MEDIA_INTEGRITY')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('errorTile_ERR_GPS_BOUNDS')), findsNothing);
      await tapKey(tester, 'errorGuideBackButton');
      expect(find.text('Settings'), findsOneWidget);
    },
  );

  testWidgets(
    'Recent issue opens promoted guidance and explicit history clearing preserves live error',
    (tester) async {
      controller.error = 'Latitude must be between -90 and 90';
      controller.recordError(controller.error!);
      await pumpSettings(tester);
      expect(find.byKey(const Key('recentErrorBanner')), findsOneWidget);
      await tapKey(tester, 'viewRecentErrorFixButton');
      expect(find.byKey(const Key('latestIssueCard')), findsOneWidget);
      expect(find.byKey(const Key('errorTile_ERR_GPS_BOUNDS')), findsNothing);
      await tapKey(tester, 'viewLatestSteps');
      expect(
        find.textContaining('Geographic coordinates must fall'),
        findsOneWidget,
      );
      await tapKey(tester, 'errorGuideBackButton');
      await tapKey(tester, 'dismissRecentErrorButton');
      expect(controller.lastErrorCode, isNull);
      expect(controller.error, 'Latitude must be between -90 and 90');
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} theme reaches Settings, nested routes, error guide and legal reader at enlarged text',
      (tester) async {
        await pumpSettings(tester, brightness: brightness, scale: 1.5);
        final expected = brightness == Brightness.dark
            ? AppTheme.dark
            : AppTheme.light;
        expect(
          Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
          brightness,
        );
        expect(
          AppTheme.of(tester.element(find.byType(SettingsScreen))).background,
          expected.background,
        );
        for (final route in [
          'appearanceRow',
          'localProjectsRow',
          'savedPresetsRow',
          'photosAttributionRow',
          'mediaExportDetails',
          'engineDetails',
          'appInformationRow',
        ]) {
          await tapKey(tester, route);
          expect(
            Theme.of(tester.element(find.byType(SettingsDestination)))
                .brightness,
            brightness,
          );
          expect(tester.takeException(), isNull, reason: route);
          await tapKey(tester, 'settingsDestinationBack');
        }
        await tapKey(tester, 'errorGuideRow');
        final field = tester.widget<TextField>(
          find.byKey(const Key('errorSearchInput')),
        );
        expect(field.style?.color, expected.text);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'errorGuideBackButton');
        await tapKey(tester, 'privacyPolicyRow');
        final legal = tester.widget<SelectableText>(
          find.byType(SelectableText),
        );
        expect(legal.style?.color, expected.text);
        final sheet = tester.widget<Container>(
          find.byKey(const Key('legalDocumentSheet')),
        );
        expect((sheet.decoration as BoxDecoration).color, expected.surface);
        expect(tester.takeException(), isNull);
        await tapKey(tester, 'closeLegalSheetButton');
      },
    );
  }
}
