import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';

import 'fake_media_bridge.dart';

void main() {
  late FakeMediaBridge bridge;
  late EditorController controller;
  setUp(() {
    bridge = FakeMediaBridge();
    controller = EditorController(bridge);
  });
  tearDown(() => controller.dispose());
  Future<void> import() async {
    await controller.initialize();
    await controller.importMedia(photos: false);
  }

  const patch = CameraPatch(make: 'Test Make', model: 'Test Camera');

  test('recovers history without automatically selecting or acknowledging an output', () async {
    bridge.sessions = [fixture(status: IntegrityStatus.incomplete)];
    await controller.initialize();
    expect(controller.sessions.length, 1);
    expect(controller.selected, isNull);
    controller.select(controller.sessions.first);
    expect(controller.canExport, isFalse);
    expect(controller.acknowledged, isFalse);
  });
  test(
    'incomplete export requires an acknowledgment tied to its frozen output',
    () async {
      await import();
      await controller.process(patch);
      expect(controller.canExport, isFalse);
      await controller.exportFiles();
      expect(bridge.exports, 0);
      controller.acknowledge(true);
      await controller.exportFiles();
      expect(bridge.exportedProcessingId, outputId);
      expect(bridge.exportedAcknowledgment, isTrue);
      expect(controller.notice, contains('Files'));
      bridge.nextProcessingId = nextOutputId;
      await controller.process(patch);
      expect(controller.acknowledged, isFalse);
      expect(controller.canExport, isFalse);
    },
  );
  test('mismatch export is blocked even when acknowledgment is set', () async {
    await import();
    bridge.nextStatus = IntegrityStatus.mismatch;
    await controller.process(patch);
    controller.acknowledge(true);
    await controller.exportFiles();
    expect(controller.canExport, isFalse);
    expect(bridge.exports, 0);
  });
  test(
    'a failed individual check blocks a contradictory verified report',
    () async {
      await controller.initialize();
      controller.select(
        fixture(status: IntegrityStatus.verified, failedCheck: true),
      );
      await controller.exportFiles();
      expect(bridge.exports, 0);
    },
  );
  test(
    'verified reports export without an unnecessary acknowledgment',
    () async {
      await import();
      bridge.nextStatus = IntegrityStatus.verified;
      await controller.process(patch);
      expect(controller.canExport, isTrue);
      await controller.exportFiles();
      expect(bridge.exportedAcknowledgment, isFalse);
    },
  );
  test(
    'cancel does not release the busy lease or accept replacement work',
    () async {
      await controller.initialize();
      bridge.pendingImport = Completer<MediaSession?>();
      final importing = controller.importMedia(photos: false);
      await controller.cancel();
      expect(controller.busy, isTrue);
      await controller.importMedia(photos: true);
      expect(bridge.imports, 1);
      bridge.pendingImport!.complete(null);
      await importing;
      expect(controller.busy, isFalse);
      expect(controller.selected, isNull);
      expect(bridge.cancels, 1);
    },
  );
  test(
    'a late processed result is recovered but never silently acknowledged',
    () async {
      await import();
      bridge.pendingProcess = Completer<MediaSession>();
      final processing = controller.process(patch);
      await controller.cancel();
      bridge.pendingProcess!.complete(
        fixture(status: IntegrityStatus.incomplete),
      );
      await processing;
      expect(controller.busy, isFalse);
      expect(controller.notice, contains('cancellation'));
      expect(controller.canExport, isFalse);
      expect(controller.acknowledgedProcessingId, isNull);
    },
  );
  test(
    'failure clears stale processing output and leaves the original selected',
    () async {
      await import();
      await controller.process(patch);
      controller.acknowledge(true);
      bridge.processError = PlatformException(
        code: 'unsupported',
        message: 'Unsupported HEIC layout.',
      );
      await controller.process(patch);
      expect(controller.selected?.processing, isNull);
      expect(controller.canExport, isFalse);
      expect(controller.error, 'Unsupported HEIC layout.');
      expect(controller.busy, isFalse);
    },
  );
  test('HEIC rejects Unicode and video rejects lens before dispatch', () async {
    await import();
    await controller.process(const CameraPatch(make: 'Caméra', model: 'Test'));
    expect(bridge.processes, 0);
    expect(controller.error, contains('ASCII'));
    controller.select(fixture(kind: MediaKind.mov));
    await controller.process(
      const CameraPatch(make: 'Camera', model: 'Test', lens: 'Lens'),
    );
    expect(bridge.processes, 0);
    expect(controller.error, contains('images only'));
  });
  test('UTF-8 byte limit and control character validation differ from character count', () {
    expect(
      CameraPatch(make: 'é' * 129, model: 'Model').validate(MediaKind.jpeg),
      isNotNull,
    );
    expect(
      const CameraPatch(
        make: 'Apple\n',
        model: 'Model',
      ).validate(MediaKind.jpeg),
      isNotNull,
    );
    expect(
      const CameraPatch(
        make: 'Apple',
        model: 'Model',
        lens: null,
      ).validate(MediaKind.mov),
      isNull,
    );
  });
  test('failed startup disables operations and a retry recovers', () async {
    bridge.startupError = const FormatException('Version mismatch');
    await controller.initialize();
    expect(controller.ready, isFalse);
    expect(controller.error, isNotNull);
    await controller.importMedia(photos: true);
    expect(bridge.imports, 0);
    bridge.startupError = null;
    await controller.initialize();
    expect(controller.ready, isTrue);
    expect(controller.error, isNull);
  });
  test(
    'deleting only requests removal of the selected opaque session',
    () async {
      await import();
      await controller.delete(controller.selected!);
      expect(bridge.deletedIds, [sourceId]);
      expect(controller.sessions, isEmpty);
      expect(controller.selected, isNull);
    },
  );
  test(
    'a response for the wrong camera patch never becomes exportable',
    () async {
      await import();
      bridge.pendingProcess = Completer<MediaSession>();
      final pending = controller.process(patch);
      bridge.pendingProcess!.complete(
        fixture(
          status: IntegrityStatus.verified,
          patch: const CameraPatch(
            make: 'Different Make',
            model: 'Different Camera',
          ),
        ),
      );
      await pending;
      expect(controller.selected?.processing, isNull);
      expect(controller.canExport, isFalse);
      expect(controller.error, contains('invalid response'));
    },
  );
  test(
    'failed delete reconciles a journal removal already committed natively',
    () async {
      await import();
      bridge.deleteAfterCommitError = PlatformException(
        code: 'storage',
        message: 'Local cleanup is incomplete.',
      );
      await controller.delete(controller.selected!);
      expect(controller.sessions, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.error, 'Local cleanup is incomplete.');
      expect(controller.busy, isFalse);
    },
  );
  test(
    'failed clear reconciles native history and retains the cleanup error',
    () async {
      await import();
      bridge.clearAfterCommitError = PlatformException(
        code: 'storage',
        message: 'Local cleanup is incomplete.',
      );
      await controller.clear();
      expect(controller.sessions, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.error, 'Local cleanup is incomplete.');
    },
  );
  test(
    'export refusal refreshes corrected incomplete checks and requires review',
    () async {
      await import();
      bridge.nextStatus = IntegrityStatus.verified;
      await controller.process(patch);
      expect(controller.canExport, isTrue);
      bridge.correctedExportSessions = [
        fixture(status: IntegrityStatus.incomplete),
      ];
      bridge.exportError = PlatformException(
        code: 'unsupported',
        message: 'Review the updated limitations.',
      );
      await controller.exportFiles();
      expect(controller.selected?.id, sourceId);
      expect(controller.selected?.processing?.id, outputId);
      expect(
        controller.selected?.processing?.integrity.status,
        IntegrityStatus.incomplete,
      );
      expect(controller.error, 'Review the updated limitations.');
      expect(controller.acknowledged, isFalse);
      expect(controller.canExport, isFalse);
      controller.acknowledge(true);
      bridge.exportError = null;
      await controller.exportFiles();
      expect(bridge.exports, 2);
      expect(bridge.exportedAcknowledgment, isTrue);
    },
  );
  test(
    'failed reconciliation preserves operation error and blocks stale export',
    () async {
      await import();
      bridge.nextStatus = IntegrityStatus.verified;
      await controller.process(patch);
      bridge.exportError = PlatformException(
        code: 'storage',
        message: 'Cannot export this copy.',
      );
      bridge.historyError = PlatformException(
        code: 'storage',
        message: 'Cannot read history.',
      );
      await controller.exportFiles();
      expect(controller.error, 'Cannot export this copy.');
      expect(controller.notice, contains('Retry startup'));
      expect(controller.ready, isFalse);
      expect(controller.canExport, isFalse);
      bridge.historyError = null;
      await controller.initialize();
      expect(controller.ready, isTrue);
      expect(controller.selected, isNull);
    },
  );
  test('disposing during an import ignores its late completion', () async {
    await controller.initialize();
    bridge.pendingImport = Completer<MediaSession?>();
    final pending = controller.importMedia(photos: true);
    controller.dispose();
    bridge.pendingImport!.complete(fixture());
    await pending;
    expect(controller.selected, isNull);
    controller = EditorController(
      bridge,
    ); // teardown disposes the replacement only.
  });
}
