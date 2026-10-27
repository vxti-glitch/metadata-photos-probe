import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/camera_profiles.dart';
import 'package:metadata_editor/editor_app.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';

import 'fake_media_bridge.dart';

const _captureEnabled = bool.fromEnvironment('AUREL_CAPTURE_PREVIEW');

Directory _materialFonts() {
  final configuredRoot = Platform.environment['FLUTTER_ROOT'];
  if (configuredRoot != null) {
    final fonts = Directory(
      '$configuredRoot/bin/cache/artifacts/material_fonts',
    );
    if (fonts.existsSync()) return fonts;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final fonts = Directory(
      '${directory.path}/bin/cache/artifacts/material_fonts',
    );
    if (fonts.existsSync()) return fonts;
    directory = directory.parent;
  }
  throw StateError('Set FLUTTER_ROOT to the SDK used for preview capture.');
}

Future<void> _loadFonts() async {
  final fonts = _materialFonts();
  final roboto = FontLoader('Roboto');
  for (final weight in ['regular', 'medium', 'bold']) {
    roboto.addFont(
      File('${fonts.path}/roboto-$weight.ttf')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)),
    );
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      File('${fonts.path}/materialicons-regular.otf')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)),
    );
  await icons.load();
}

MediaSession _sample(String id, String name) {
  final sample = fixture(
    id: id,
    additionalMetadata: {
      'make': 'Apple',
      'model': 'iPhone 16 Pro',
      'lens': 'iPhone 16 Pro back triple camera 6.765mm f/1.78',
      'iso': '80',
      'fNumber': '1.78',
      'focalLength': '6.765',
      'dateTimeOriginal': '2026:10:15 14:32:08',
    },
    additionalStructure: {'width': '4032', 'height': '3024'},
  );
  return MediaSession(
    id: sample.id,
    displayName: name,
    origin: sample.origin,
    createdAt: sample.createdAt,
    inspection: sample.inspection,
    notes: sample.notes,
    details: sample.details,
  );
}

void main() {
  testWidgets(
    'capture home, Settings and populated editors in both appearances',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await _loadFonts();
        await loadCameraProfiles();
      });

      final bridge = FakeMediaBridge();
      final controller = EditorController(bridge);
      addTearDown(controller.dispose);
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: MetadataEditorApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 3);
          try {
            expect(image.width, 1170);
            expect(image.height, 2532);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File('../build/aurel-preview/$name.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      for (final appearance in ['light', 'dark']) {
        await controller.setAppearance(appearance);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('selectMedia')), findsOneWidget);
        await capture('home-$appearance');
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        await capture('settings-$appearance');
        await tester.tap(find.byKey(const Key('settingsBackButton')));
        await tester.pumpAndSettle();
      }

      final samples = [
        _sample(sourceId, 'IMG_4827.HEIC'),
        _sample(outputId, 'IMG_4828.HEIC'),
        _sample(nextOutputId, 'IMG_4829.HEIC'),
      ];
      for (final appearance in ['dark', 'light']) {
        await controller.setAppearance(appearance);
        bridge.batchImportResult = [samples.first];
        await controller.importBatch(photos: false);
        await tester.pumpAndSettle();
        expect(find.text('Edit metadata'), findsOneWidget);
        expect(find.text('Your phone'), findsOneWidget);
        await capture('editor-$appearance');

        bridge.batchImportResult = samples;
        await controller.importBatch(photos: false);
        controller.dismissMessage();
        await tester.pumpAndSettle();
        expect(find.text('3 selected'), findsOneWidget);
        expect(find.text('One shared metadata plan'), findsOneWidget);
        await capture('batch-$appearance');
      }
    },
    skip: !_captureEnabled,
  );
}
