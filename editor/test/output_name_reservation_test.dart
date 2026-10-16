import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/metadata_patch.dart';

import 'fake_media_bridge.dart';

void main() {
  test(
    'each file reserves a stable unique name consumed only by success',
    () async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: outputId)];
      final controller = EditorController(bridge);
      await controller.initialize();
      final names = await controller.reserveOutputNames([sourceId, outputId]);
      expect(names.length, 2);
      expect(names.values.toSet().length, 2);
      expect(await controller.reserveOutputNames([outputId, sourceId]), names);
      bridge.processError = PlatformException(code: 'processing');
      await expectLater(
        bridge.processMetadata(
          sourceId,
          MetadataPatch(values: {'make': 'Apple'}),
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(bridge.reservedOutputNames[sourceId], names[sourceId]);
      bridge.processError = null;
      final processed = await bridge.processMetadata(
        sourceId,
        MetadataPatch(values: {'make': 'Apple'}),
      );
      expect(processed.processing!.outputDisplayName, names[sourceId]);
      expect(bridge.reservedOutputNames.containsKey(sourceId), isFalse);
      expect(bridge.reservedOutputNames[outputId], names[outputId]);
      controller.dispose();
    },
  );

  test(
    'preparing names serializes work, cannot cancel and reports failure',
    () async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = EditorController(bridge);
      await controller.initialize();
      bridge.pendingReservation = Completer<Map<String, String>>();
      final pending = controller.reserveOutputNames([sourceId]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.operation, EditorOperation.preparingCopies);
      expect(controller.progressLabel, contains('Preparing names'));
      await controller.cancel();
      expect(bridge.cancels, 0);
      expect(await controller.reserveOutputNames([sourceId]), isEmpty);
      bridge.pendingReservation!.completeError(
        PlatformException(
          code: 'storage',
          message: 'Reserved name already exists.',
        ),
      );
      expect(await pending, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.error, contains('already exists'));
      controller.dispose();
    },
  );

  test('nonexistent sources never cross the reservation bridge', () async {
    final bridge = FakeMediaBridge();
    final controller = EditorController(bridge);
    await controller.initialize();
    expect(await controller.reserveOutputNames([sourceId]), isEmpty);
    expect(bridge.reservations, 0);
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test(
    'controller refuses reserved names with the wrong media extension',
    () async {
      final bridge = FakeMediaBridge()..sessions = [fixture()];
      final controller = EditorController(bridge);
      await controller.initialize();
      bridge.pendingReservation = Completer<Map<String, String>>()
        ..complete({sourceId: 'IMG_1234.MP4'});
      expect(await controller.reserveOutputNames([sourceId]), isEmpty);
      expect(controller.error, contains('Invalid output name reservation'));
      controller.dispose();
    },
  );
}
