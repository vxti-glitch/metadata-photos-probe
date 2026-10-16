import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_patch.dart';

import 'fake_media_bridge.dart';

class _GatedSaveMediaBridge extends FakeMediaBridge {
  final firstSaveStarted = Completer<void>();
  final allowFirstSaveToFinish = Completer<void>();
  final secondSaveCompleted = Completer<void>();
  final writes = <Map<String, Object?>>[];

  @override
  Future<void> saveEditorState(Map<String, Object?> state) async {
    final writeNumber = writes.length + 1;
    writes.add(Map<String, Object?>.from(state));
    if (writeNumber == 1) {
      firstSaveStarted.complete();
      await allowFirstSaveToFinish.future;
    }
    editorState = Map<String, Object?>.from(state);
    if (writeNumber == 2) secondSaveCompleted.complete();
  }
}

class _GatedOperationMediaBridge extends FakeMediaBridge {
  final processStarted = Completer<void>();
  final allowProcessToFinish = Completer<void>();
  final historySaveCompleted = Completer<void>();
  bool processing = false;
  int saves = 0;
  bool saveOverlappedProcessing = false;

  @override
  Future<void> saveEditorState(Map<String, Object?> state) async {
    saves++;
    saveOverlappedProcessing |= processing;
    await super.saveEditorState(state);
    if (saves > 0 && !historySaveCompleted.isCompleted) {
      historySaveCompleted.complete();
    }
  }

  @override
  Future<MediaSession> processMetadata(
    String sessionId,
    MetadataPatch patch,
  ) async {
    processing = true;
    processStarted.complete();
    await allowProcessToFinish.future;
    final result = await super.processMetadata(sessionId, patch);
    processing = false;
    return result;
  }
}

class _DeleteDuringMetadataFailureBridge extends FakeMediaBridge {
  @override
  Future<MediaSession> processMetadata(
    String sessionId,
    MetadataPatch patch,
  ) async {
    processes++;
    sessions.removeWhere((session) => session.id == sessionId);
    throw PlatformException(
      code: 'not_found',
      message: 'The source session was removed during processing.',
    );
  }
}

class _CapturingBatchBridge extends FakeMediaBridge {
  List<Map<String, Object?>> exportedBatch = [];

  @override
  Future<bool> exportBatch(List<Map<String, Object?>> items) async {
    exportedBatch = items;
    return super.exportBatch(items);
  }
}

class _FailingSaveMediaBridge extends FakeMediaBridge {
  final saveStarted = Completer<void>();

  @override
  Future<void> saveEditorState(Map<String, Object?> state) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    throw PlatformException(
      code: 'processing',
      message: 'Local editor state could not be saved.',
    );
  }
}

class _RecoveringSaveMediaBridge extends FakeMediaBridge {
  final firstSaveStarted = Completer<void>();
  final secondSaveCompleted = Completer<void>();
  int saveCount = 0;

  @override
  Future<void> saveEditorState(Map<String, Object?> state) async {
    saveCount++;
    if (saveCount == 1) {
      firstSaveStarted.complete();
      throw PlatformException(
        code: 'processing',
        message: 'Local editor state could not be saved.',
      );
    }
    editorState = Map<String, Object?>.from(state);
    if (saveCount == 2) secondSaveCompleted.complete();
  }
}

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
    'failed history refresh after cancellation disables stale cached exports',
    () async {
      await import();
      bridge.nextStatus = IntegrityStatus.verified;
      await controller.process(patch);
      expect(controller.canExport, isTrue);

      bridge.pendingProcess = Completer<MediaSession>();
      final processing = controller.process(patch);
      await controller.cancel();
      bridge.pendingProcess!.complete(
        fixture(status: IntegrityStatus.verified, processingId: nextOutputId),
      );
      bridge.historyError = PlatformException(
        code: 'storage',
        message: 'History unavailable.',
      );
      await processing;

      expect(controller.ready, isFalse);
      expect(controller.canExport, isFalse);
      expect(controller.error, 'History unavailable.');
      expect(controller.lastErrorCode, 'ERR_STORAGE_FULL');
      expect(controller.notice, contains('Retry startup'));
      expect(bridge.exports, 0);
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
  test('failed batch delete removes stale selection and queue entries after commit', () async {
    final items = [
      fixture(id: 's-delete', kind: MediaKind.jpeg),
      fixture(id: 's-keep', kind: MediaKind.jpeg),
    ];
    bridge.sessions = items;
    await controller.initialize();
    for (final item in items) {
      controller.toggleBatch(item, true);
    }
    controller.queue = [
      QueueItem('s-delete', MetadataPatch(values: {'make': 'Brand'})),
      QueueItem('s-keep', MetadataPatch(values: {'make': 'Brand'})),
    ];
    controller.startBatchEditing();
    expect(controller.isBatchMode, isTrue);

    bridge.deleteAfterCommitError = PlatformException(
      code: 'storage',
      message: 'Local cleanup is incomplete.',
    );
    await controller.delete(items.first);

    expect(controller.sessions.map((item) => item.id), ['s-keep']);
    expect(controller.batchSelection, {'s-keep'});
    expect(controller.queue.map((item) => item.sessionId), ['s-keep']);
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, 's-keep');
    expect(controller.error, 'Local cleanup is incomplete.');
  });
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
    'failed batch clear after commit clears stale batch mode and queue',
    () async {
      final items = [
        fixture(id: 's-clear-1', kind: MediaKind.jpeg),
        fixture(id: 's-clear-2', kind: MediaKind.png),
      ];
      bridge.sessions = items;
      await controller.initialize();
      for (final item in items) {
        controller.toggleBatch(item, true);
      }
      controller.queue = [
        QueueItem('s-clear-1', MetadataPatch(values: {'make': 'Brand'})),
        QueueItem('s-clear-2', MetadataPatch(values: {'make': 'Brand'})),
      ];
      controller.startBatchEditing();
      expect(controller.isBatchMode, isTrue);

      bridge.clearAfterCommitError = PlatformException(
        code: 'storage',
        message: 'Local cleanup is incomplete.',
      );
      await controller.clear();

      expect(controller.sessions, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.batchSelection, isEmpty);
      expect(controller.queue, isEmpty);
      expect(controller.isBatchMode, isFalse);
      expect(controller.error, 'Local cleanup is incomplete.');
    },
  );
  test('starting batch editing safely drops stale selection IDs', () async {
    await controller.initialize();
    controller.batchSelection.add('missing-session');
    controller.isBatchMode = true;

    controller.startBatchEditing();

    expect(controller.batchSelection, isEmpty);
    expect(controller.isBatchMode, isFalse);
    expect(controller.selected, isNull);
  });
  test(
    'batch processing safely handles a session removed during failed recovery',
    () async {
      final deletingBridge = _DeleteDuringMetadataFailureBridge()
        ..sessions = [fixture(id: 's-removed', kind: MediaKind.jpeg)];
      final deletingController = EditorController(deletingBridge);
      addTearDown(deletingController.dispose);
      await deletingController.initialize();
      final source = deletingController.sessions.single;
      deletingController.toggleBatch(source, true);
      deletingController.startBatchEditing();

      await deletingController.processBatch({
        source.id: MetadataPatch(values: {'make': 'Brand'}),
      });

      expect(deletingBridge.processes, 1);
      expect(deletingController.sessions, isEmpty);
      expect(deletingController.selected, isNull);
      expect(deletingController.batchSelection, isEmpty);
      expect(deletingController.queue, isEmpty);
      expect(deletingController.isBatchMode, isFalse);
      expect(deletingController.canExport, isFalse);
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

  test('shareFiles invokes bridge shareFiles with proper parameters', () async {
    await import();
    bridge.nextStatus = IntegrityStatus.verified;
    await controller.process(patch);
    expect(controller.canExport, isTrue);
    await controller.shareFiles();
    expect(bridge.shares, 1);
    expect(bridge.sharedProcessingId, outputId);
    expect(bridge.sharedAcknowledgment, isFalse);
  });

  test('batch processing across mixed formats PNG, JPEG, HEIC, MP4, MOV isolates format capabilities and handles partial failures', () async {
    await controller.initialize();
    final items = [
      fixture(id: 's-jpeg', kind: MediaKind.jpeg),
      fixture(id: 's-heic', kind: MediaKind.heic),
      fixture(id: 's-png', kind: MediaKind.png),
      fixture(id: 's-mp4', kind: MediaKind.mp4),
      fixture(id: 's-mov', kind: MediaKind.mov),
    ];
    bridge.sessions = items;
    await controller.initialize();
    for (final item in items) {
      controller.toggleBatch(item, true);
    }
    expect(controller.batchSelection.length, 5);
    controller.startBatchEditing();
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, items.first.id);

    final batchMap = {
      for (final s in items)
        s.id: MetadataPatch(values: {'make': 'BrandX', 'model': 'ModelY'}),
    };
    bridge.nextStatus = IntegrityStatus.verified;
    await controller.processBatch(batchMap);
    expect(controller.queue.length, 5);
    expect(controller.queueTotal, 5);
    expect(controller.queueCompletedCount, 5);
    expect(controller.queueFailedCount, 0);
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, items.first.id);
    expect(
      controller.sessions.every((session) => session.processing != null),
      isTrue,
    );

    controller.queue.first.status = 'failed';
    controller.queue.first.message = 'Verification mismatch';
    expect(controller.queueFailedCount, 1);

    await controller.exportSelectedBatch(onlyReady: true);
    expect(bridge.exports, 1);

    await controller.shareSelectedBatch(onlyReady: true);
    expect(bridge.shares, 1);

    await controller.retryBatch();
    expect(controller.queue.first.status, 'completed');
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, items.first.id);
  });

  test('batch queue cancellation stops pending items', () async {
    await controller.initialize();
    final items = [
      fixture(id: 's-1', kind: MediaKind.jpeg),
      fixture(id: 's-2', kind: MediaKind.jpeg),
    ];
    bridge.sessions = items;
    await controller.initialize();
    for (final item in items) {
      controller.toggleBatch(item, true);
    }
    controller.startBatchEditing();
    final batchMap = {
      's-1': MetadataPatch(values: {'make': 'Brand'}),
      's-2': MetadataPatch(values: {'make': 'Brand'}),
    };
    bridge.metadataLease = Completer<void>();
    final processingFuture = controller.processBatch(batchMap);
    await controller.cancel();
    expect(controller.cancellationRequested, isTrue);
    bridge.metadataLease!.complete();
    await processingFuture;
    expect(
      controller.queue.any(
        (q) => q.status == 'interrupted' || q.status == 'pending',
      ),
      isTrue,
    );
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, items.first.id);
  });

  test('single-file replacement invalidates the old completed batch plan before export', () async {
    final batchBridge = _CapturingBatchBridge()
      ..sessions = [
        fixture(id: 's-batch-a', kind: MediaKind.jpeg),
        fixture(id: 's-batch-b', kind: MediaKind.jpeg),
      ]
      ..nextStatus = IntegrityStatus.verified;
    final batchController = EditorController(batchBridge);
    addTearDown(batchController.dispose);
    await batchController.initialize();
    for (final source in batchController.sessions) {
      batchController.toggleBatch(source, true);
    }
    batchController.startBatchEditing();
    final originalPlan = MetadataPatch(values: {'make': 'Batch Brand'});
    await batchController.processBatch({
      's-batch-a': originalPlan,
      's-batch-b': originalPlan,
    });
    expect(
      batchController.queue.every((item) => item.status == 'completed'),
      isTrue,
    );

    final changedSource = batchController.sessions.firstWhere(
      (source) => source.id == 's-batch-a',
    );
    batchController.select(changedSource);
    await batchController.processMetadata(
      MetadataPatch(values: {'make': 'Single-file Brand'}),
    );

    final changedQueueItem = batchController.queue.firstWhere(
      (item) => item.sessionId == 's-batch-a',
    );
    expect(changedQueueItem.status, 'interrupted');
    expect(
      batchController.sessions
          .firstWhere((source) => source.id == 's-batch-a')
          .processing!
          .metadataPatch!
          .equivalent(originalPlan),
      isFalse,
    );

    await batchController.exportSelectedBatch(onlyReady: true);
    expect(batchBridge.exportedBatch, hasLength(1));
    expect(batchBridge.exportedBatch.single['sessionId'], 's-batch-b');
  });

  test('failed single-file replacement clears its completed batch output qualification', () async {
    final batchBridge = FakeMediaBridge()
      ..sessions = [fixture(id: 's-batch-failed', kind: MediaKind.jpeg)]
      ..nextStatus = IntegrityStatus.verified;
    final batchController = EditorController(batchBridge);
    addTearDown(batchController.dispose);
    await batchController.initialize();
    final source = batchController.sessions.single;
    batchController.toggleBatch(source, true);
    batchController.startBatchEditing();
    final batchPlan = MetadataPatch(values: {'make': 'Batch Brand'});
    await batchController.processBatch({source.id: batchPlan});
    expect(batchController.queue.single.status, 'completed');

    batchController.select(batchController.sessions.single);
    batchBridge.processError = PlatformException(
      code: 'processing',
      message: 'Single-file edit failed.',
    );
    await batchController.processMetadata(
      MetadataPatch(values: {'make': 'Replacement Brand'}),
    );

    expect(batchController.queue.single.status, 'interrupted');
    expect(batchController.selected?.processing, isNull);
    expect(batchController.canExport, isFalse);
  });

  test('importBatch with multiple files enters batch mode directly', () async {
    await controller.initialize();
    final items = [
      fixture(id: 's-1', kind: MediaKind.jpeg),
      fixture(id: 's-2', kind: MediaKind.png),
    ];
    bridge.batchImportResult = items;
    await controller.importBatch(photos: true);
    expect(controller.isBatchMode, isTrue);
    expect(controller.batchSelection.length, 2);
    expect(controller.selected?.id, 's-1');

    controller.exitBatchEditing();
    expect(controller.isBatchMode, isFalse);
    expect(controller.selected, isNull);

    controller.startBatchEditing();
    expect(controller.isBatchMode, isTrue);
    expect(controller.selected?.id, 's-1');
  });

  test(
    'rememberSelectedProfile persists and restores across re-initialization',
    () async {
      await controller.initialize();
      await controller.rememberSelectedProfile(
        brand: 'Apple',
        profileId: 'iphone-15-pro-max',
        cameraId: 'main-24mm',
      );
      expect(controller.selectedBrand, 'Apple');
      expect(controller.selectedProfileId, 'iphone-15-pro-max');
      expect(controller.selectedCameraId, 'main-24mm');

      // Create a new controller instance with the same bridge to test reload
      final restoredController = EditorController(bridge);
      await restoredController.initialize();
      expect(restoredController.selectedBrand, 'Apple');
      expect(restoredController.selectedProfileId, 'iphone-15-pro-max');
      expect(restoredController.selectedCameraId, 'main-24mm');

      // Reset presets also clears saved profile selection
      await restoredController.resetPresets();
      expect(restoredController.selectedBrand, isNull);
      expect(restoredController.selectedProfileId, isNull);
      expect(restoredController.selectedCameraId, isNull);

      // Verify that after reset and another reload cycle, keys remain cleared in storage
      final thirdController = EditorController(bridge);
      await thirdController.initialize();
      expect(thirdController.selectedBrand, isNull);
      expect(thirdController.selectedProfileId, isNull);
      expect(thirdController.selectedCameraId, isNull);
    },
  );
  test('profile preference persistence failures are reported without escaping UI callbacks', () async {
    await controller.initialize();
    bridge.stateSaveError = PlatformException(
      code: 'storage',
      message: 'Preferences could not be saved.',
    );

    await expectLater(
      controller.rememberSelectedProfile(
        brand: 'Apple',
        profileId: 'iphone-test',
        cameraId: 'main',
      ),
      completes,
    );
    expect(controller.selectedProfileId, 'iphone-test');
    expect(controller.lastErrorMessage, 'Preferences could not be saved.');
  });

  test('resetPresets reports storage failure and rolls state back', () async {
    await controller.initialize();
    await controller.savePreset(
      'Keep this preset',
      MetadataPatch(values: {'make': 'Apple'}),
    );
    bridge.stateSaveError = PlatformException(
      code: 'storage',
      message: 'Preset storage is unavailable.',
    );

    await expectLater(controller.resetPresets(), completes);
    expect(controller.presets.map((preset) => preset.name), [
      'Keep this preset',
    ]);
    expect(controller.lastErrorMessage, 'Preset storage is unavailable.');
    expect(controller.busy, isFalse);
  });

  test('resetPresets cannot run while media processing is active', () async {
    await controller.initialize();
    await controller.savePreset(
      'Keep this preset',
      MetadataPatch(values: {'make': 'Apple'}),
    );
    bridge.sessions = [fixture()];
    await controller.initialize();
    controller.select(controller.sessions.single);
    bridge.metadataLease = Completer<void>();
    final processing = controller.processMetadata(
      MetadataPatch(values: {'iso': 200}),
    );
    for (var i = 0; i < 5 && bridge.processes == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.busy, isTrue);

    await controller.resetPresets();
    expect(controller.presets.map((preset) => preset.name), [
      'Keep this preset',
    ]);

    bridge.metadataLease!.complete();
    await processing;
  });

  test(
    'exportSelectedBatch sets clear qualification message when copies unready',
    () async {
      final items = [fixture(id: 's-unready-1', kind: MediaKind.jpeg)];
      bridge.sessions = items;
      await controller.initialize();
      controller.toggleBatch(items.first, true);

      await controller.exportSelectedBatch();
      expect(controller.error, contains('No processed copies are ready'));
    },
  );

  test(
    'exportSelectedBatch sets partial unready message when some copies unready',
    () async {
      final readyItem = fixture(
        id: 's-ready-1',
        kind: MediaKind.jpeg,
        status: IntegrityStatus.verified,
      );
      final unreadyItem = fixture(id: 's-unready-2', kind: MediaKind.jpeg);
      bridge.sessions = [readyItem, unreadyItem];
      await controller.initialize();
      controller.toggleBatch(readyItem, true);
      controller.toggleBatch(unreadyItem, true);

      await controller.exportSelectedBatch();
      expect(
        controller.error,
        contains('Selected files contain unprocessed copies'),
      );
    },
  );

  test('classifyErrorCode correctly categorizes error messages', () {
    expect(
      EditorController.classifyErrorCode('Invalid date format in EXIF header'),
      'ERR_DATE_FMT',
    );
    expect(
      EditorController.classifyErrorCode('Latitude must be between -90 and 90'),
      'ERR_GPS_BOUNDS',
    );
    expect(
      EditorController.classifyErrorCode(
        'Independent integrity verification failed: retained embedded metadata mismatch',
      ),
      'ERR_MEDIA_INTEGRITY',
    );
    expect(
      EditorController.classifyErrorCode(
        'make cannot be changed and removed together',
      ),
      'ERR_FIELD_CONFLICT',
    );
    expect(
      EditorController.classifyErrorCode('No processed copies are ready'),
      'ERR_EXPORT_UNREADY',
    );
    expect(
      EditorController.classifyErrorCode('Photos access permission denied'),
      'ERR_PHOTOS_ACCESS',
    );
    expect(
      EditorController.classifyErrorCode('Insufficient disk storage space'),
      'ERR_STORAGE_FULL',
    );
    expect(
      EditorController.classifyErrorCode('Unsupported container or codec'),
      'ERR_UNSUPPORTED_MEDIA',
    );
    expect(
      EditorController.classifyErrorCode('Unexpected internal failure.'),
      'ERR_PROCESSING',
    );
  });
  test('native diagnostic codes map to the matching user guide category', () {
    expect(
      EditorController.classifyFailureCode(
        PlatformException(code: 'readback', message: 'Fixed safe message.'),
        'Fixed safe message.',
      ),
      'ERR_MEDIA_INTEGRITY',
    );
    expect(
      EditorController.classifyFailureCode(
        PlatformException(code: 'unsupported', message: 'Fixed safe message.'),
        'Fixed safe message.',
      ),
      'ERR_UNSUPPORTED_MEDIA',
    );
    expect(
      EditorController.classifyFailureCode(
        PlatformException(code: 'storage', message: 'Fixed safe message.'),
        'Fixed safe message.',
      ),
      'ERR_STORAGE_FULL',
    );
    expect(
      EditorController.classifyFailureCode(
        PlatformException(code: 'processing', message: 'Fixed safe message.'),
        'Fixed safe message.',
      ),
      'ERR_PROCESSING',
    );
  });

  test('recordError and clearLastError persist and restore across re-initialization', () async {
    await controller.initialize();
    expect(controller.lastErrorCode, isNull);

    controller.recordError(
      'Native metadata processing or independent integrity verification failed',
    );
    expect(controller.lastErrorCode, 'ERR_MEDIA_INTEGRITY');
    expect(
      controller.lastErrorMessage,
      'Native metadata processing or independent integrity verification failed',
    );
    expect(controller.lastErrorTime, isNotNull);

    // Verify persistence across re-initialization
    final restored = EditorController(bridge);
    await restored.initialize();
    expect(restored.lastErrorCode, 'ERR_MEDIA_INTEGRITY');
    expect(
      restored.lastErrorMessage,
      'Native metadata processing or independent integrity verification failed',
    );
    expect(restored.lastErrorTime, isNotNull);

    // Clear error and verify persistence
    restored.error = 'The current operation still needs attention.';
    restored.clearLastError();
    expect(restored.lastErrorCode, isNull);
    expect(restored.lastErrorMessage, isNull);
    expect(restored.lastErrorTime, isNull);
    expect(
      restored.error,
      'The current operation still needs attention.',
      reason: 'Clearing persisted history must not imply the current issue is fixed.',
    );

    final third = EditorController(bridge);
    await third.initialize();
    expect(third.lastErrorCode, isNull);
    expect(third.lastErrorMessage, isNull);
  });

  test('error history writes are serialized so a clear cannot be overwritten', () async {
    final orderedBridge = _GatedSaveMediaBridge();
    final orderedController = EditorController(orderedBridge);
    addTearDown(orderedController.dispose);
    await orderedController.initialize();

    orderedController.recordError('A recent processing error');
    await orderedBridge.firstSaveStarted.future;
    orderedController.clearLastError();
    await Future<void>.delayed(Duration.zero);

    // The clear is queued until the first write finishes, instead of racing it.
    expect(orderedBridge.writes, hasLength(1));
    orderedBridge.allowFirstSaveToFinish.complete();
    await orderedBridge.secondSaveCompleted.future;

    expect(orderedBridge.editorState.containsKey('lastErrorCode'), isFalse);
    expect(orderedBridge.editorState.containsKey('lastErrorMessage'), isFalse);
    expect(orderedController.statePersistenceError, isNull);
  });

  test(
    'an idle history save finishes before media processing starts',
    () async {
      final gatedBridge = _GatedSaveMediaBridge();
      gatedBridge.sessions = [fixture()];
      final gatedController = EditorController(gatedBridge);
      addTearDown(gatedController.dispose);
      await gatedController.initialize();
      gatedController.select(gatedController.sessions.single);

      gatedController.recordError('A recent processing error');
      await gatedBridge.firstSaveStarted.future;
      final processing = gatedController.processMetadata(
        MetadataPatch(values: {'make': 'Updated'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(gatedBridge.processes, 0);

      gatedBridge.allowFirstSaveToFinish.complete();
      await processing;
      expect(gatedBridge.processes, 1);
    },
  );

  test(
    'error history changes during processing are deferred until it finishes',
    () async {
      final gatedBridge = _GatedOperationMediaBridge();
      gatedBridge.sessions = [fixture()];
      final gatedController = EditorController(gatedBridge);
      addTearDown(gatedController.dispose);
      await gatedController.initialize();
      gatedController.select(gatedController.sessions.single);

      final processing = gatedController.processMetadata(
        MetadataPatch(values: {'make': 'Updated'}),
      );
      await gatedBridge.processStarted.future;
      gatedController.recordError('A transient processing error');
      gatedController.clearLastError();
      await Future<void>.delayed(Duration.zero);
      expect(gatedBridge.saves, 0);
      expect(gatedBridge.saveOverlappedProcessing, isFalse);

      gatedBridge.allowProcessToFinish.complete();
      await processing;
      await gatedBridge.historySaveCompleted.future;
      expect(gatedBridge.saves, 1);
      expect(gatedBridge.saveOverlappedProcessing, isFalse);
      expect(gatedBridge.editorState.containsKey('lastErrorCode'), isFalse);
    },
  );

  test(
    'failed error-history persistence is exposed without losing the live error',
    () async {
      final failingBridge = _FailingSaveMediaBridge();
      final failingController = EditorController(failingBridge);
      addTearDown(failingController.dispose);
      await failingController.initialize();

      failingController.recordError('A recent processing error');
      await failingBridge.saveStarted.future;
      await Future<void>.delayed(Duration.zero);

      expect(failingController.lastErrorCode, 'ERR_PROCESSING');
      expect(
        failingController.statePersistenceError,
        contains('Local editor state could not be saved'),
      );
    },
  );

  test(
    'listeners are notified when error-history persistence recovers',
    () async {
      final recoveringBridge = _RecoveringSaveMediaBridge();
      final recoveringController = EditorController(recoveringBridge);
      addTearDown(recoveringController.dispose);
      await recoveringController.initialize();

      recoveringController.recordError('A recent processing error');
      await recoveringBridge.firstSaveStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(recoveringController.statePersistenceError, isNotNull);

      final warningCleared = Completer<void>();
      recoveringController.addListener(() {
        if (recoveringController.statePersistenceError == null &&
            !warningCleared.isCompleted) {
          warningCleared.complete();
        }
      });
      recoveringController.clearLastError();
      await recoveringBridge.secondSaveCompleted.future;
      await warningCleared.future;

      expect(recoveringController.statePersistenceError, isNull);
    },
  );

  test(
    'progress labels describe general metadata writes and website navigation',
    () {
      controller.operation = EditorOperation.processing;
      expect(
        controller.progressLabel,
        'Writing metadata and checking media integrity…',
      );
      controller.operation = EditorOperation.openingWebsite;
      expect(controller.progressLabel, 'Opening the Zlarp website…');
      controller.operation = EditorOperation.openingBrowser;
      expect(controller.progressLabel, 'Opening iCloud Photos…');
    },
  );
}
