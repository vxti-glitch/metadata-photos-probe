import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_theme.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/media_preview.dart';

import 'fake_media_bridge.dart';

void main() {
  MediaSession withPreview(String path) {
    final source = fixture();
    return MediaSession(
      id: source.id,
      displayName: source.displayName,
      origin: source.origin,
      createdAt: source.createdAt,
      inspection: source.inspection,
      notes: source.notes,
      previewPath: path,
    );
  }

  Future<void> show(
    WidgetTester tester,
    MediaSession session, {
    bool light = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: light ? AppTheme.lightTheme() : AppTheme.darkTheme(),
        home: Scaffold(
          body: Center(
            child: MediaPreview(session: session, height: 80, width: 120),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('missing preview renders bounded placeholder in both themes', (
    tester,
  ) async {
    for (final light in [true, false]) {
      await show(tester, fixture(), light: light);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
      expect(tester.getSize(find.byType(MediaPreview)), const Size(120, 80));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('video placeholder is distinct', (tester) async {
    await show(tester, fixture(kind: MediaKind.mp4));
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unreadable preview falls back without failing the editor', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'metadata-preview-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    await show(tester, withPreview('${directory.path}/missing.png'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reads only the small PNG preview with bounded image cache', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'metadata-preview-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/preview.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      ),
    );
    await show(tester, withPreview(file.path));
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    final provider = image.image as ResizeImage;
    expect(provider.width, 512);
    expect(provider.height, 512);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect((provider.imageProvider as FileImage).file.path, file.path);
    expect(tester.takeException(), isNull);
  });
}
