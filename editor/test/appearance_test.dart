import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';

import 'fake_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'appearance is restored, persisted and invalid values fall back to system',
    () async {
      final bridge = FakeMediaBridge()
        ..editorState = {'schemaVersion': 1, 'appearance': 'light'};
      final controller = EditorController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.appearance, 'light');
      await controller.setAppearance('dark');
      expect(bridge.editorState['appearance'], 'dark');
      await controller.setAppearance('invalid');
      expect(controller.appearance, 'dark');
      bridge.editorState = {'schemaVersion': 1, 'appearance': 42};
      final restored = EditorController(bridge);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.appearance, 'system');
    },
  );

  test('appearance changes immediately while busy and persists after handoff completes', () async {
    final bridge = FakeMediaBridge()
      ..supportEmailCompletion = Completer<void>();
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    final opening = controller.openSupportEmail();
    await Future<void>.delayed(Duration.zero);
    await controller.setAppearance('light');
    expect(controller.appearance, 'light');
    expect(controller.busy, isTrue);
    expect(bridge.editorState['appearance'], isNot('light'));
    bridge.supportEmailCompletion!.complete();
    await opening;
    await Future<void>.delayed(Duration.zero);
    expect(bridge.editorState['appearance'], 'light');
  });

  test('failed engine startup still restores theme and saves it without erasing stored projects or presets', () async {
    final preset = {
      'schemaVersion': 1,
      'id': sourceId,
      'name': 'Saved recipe',
      'patch': {
        'values': {'make': 'Apple'},
        'removals': <String>[],
      },
    };
    final queue = <Object?>[
      {'previous': 'opaque stored queue preserved until hydration'},
    ];
    final bridge = FakeMediaBridge()
      ..editorState = {
        'schemaVersion': 1,
        'appearance': 'dark',
        'presets': [preset],
        'queue': queue,
        'selection': [sourceId],
        'selectedBrand': 'Apple',
        'selectedProfileId': 'iphone-15-pro',
        'selectedCameraId': 'main',
      }
      ..startupError = PlatformException(
        code: 'storage',
        message: 'Engine startup failed',
      );
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(controller.ready, isFalse);
    expect(controller.appearance, 'dark');
    await controller.setAppearance('light');
    expect(bridge.editorState['appearance'], 'light');
    expect(bridge.editorState['presets'], [preset]);
    expect(bridge.editorState['queue'], queue);
    expect(bridge.editorState['selection'], [sourceId]);
    expect(bridge.editorState['selectedBrand'], 'Apple');
    expect(bridge.editorState['selectedProfileId'], 'iphone-15-pro');
    expect(bridge.editorState['selectedCameraId'], 'main');
  });

  test('theme changes preserve selected source, batch selection and acknowledgment', () async {
    final bridge = FakeMediaBridge()..sessions = [fixture()];
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    final source = bridge.sessions.single;
    controller.selected = source;
    controller.batchSelection.add(source.id);
    controller.acknowledgedProcessingId = outputId;
    await controller.setAppearance('light');
    expect(controller.selected, same(source));
    expect(controller.batchSelection, {source.id});
    expect(controller.acknowledgedProcessingId, outputId);
  });

  test('map picker receives the chosen in-app appearance', () async {
    final bridge = FakeMediaBridge();
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.setAppearance('light');
    await controller.pickLocation();
    expect(bridge.lastLocationPickerAppearance, 'light');
    await controller.setAppearance('dark');
    await controller.pickLocation();
    expect(bridge.lastLocationPickerAppearance, 'dark');
  });
}
