import 'dart:math';

import 'package:flutter/foundation.dart';

import 'app_brand.dart';
import 'camera_profiles.dart';
import 'metadata_patch.dart';

import 'media_bridge.dart';
import 'media_models.dart';

enum EditorOperation {
  loading,
  importing,
  processing,
  exporting,
  deleting,
  openingBrowser,
}

class EditorController extends ChangeNotifier {
  EditorController(this.bridge);
  final MediaBridge bridge;
  List<SavedPreset> presets = [];
  final Set<String> batchSelection = {};
  List<QueueItem> queue = [];
  Map<String, Object?> _editorState = {};
  int queueCompleted = 0;
  Future<void> _persist() async {
    final state = <String, Object?>{
      ..._editorState,
      'schemaVersion': 1,
      'presets': presets.map((p) => p.toMap()).toList(),
      'queue': queue.map((q) => q.toMap()).toList(),
      'selection': batchSelection.toList(),
    };
    await bridge.saveEditorState(state);
    _editorState = state;
  }

  List<MediaSession> _sessions = const [];
  List<MediaSession> get sessions => List.unmodifiable(_sessions);
  MediaSession? selected;
  MediaCapabilities? capabilities;
  EditorOperation? operation;
  String? error;
  String? notice;
  String? acknowledgedProcessingId;
  bool cancellationRequested = false;
  bool _disposed = false;
  int _generation = 0;
  bool get busy => operation != null;
  bool get ready => capabilities != null;
  bool get acknowledged =>
      selected?.processing != null &&
      acknowledgedProcessingId == selected!.processing!.id;
  bool get canExport {
    final processing = selected?.processing;
    return ready &&
        !busy &&
        processing != null &&
        !processing.integrity.hasMismatch &&
        (!processing.integrity.needsAcknowledgment || acknowledged);
  }

  String get progressLabel {
    if (cancellationRequested) {
      return 'Cancel requested · waiting for the current operation to finish';
    }
    return switch (operation) {
      EditorOperation.loading => 'Recovering your local projects…',
      EditorOperation.importing => 'Importing and inspecting the original…',
      EditorOperation.processing =>
        'Writing camera metadata and checking media integrity…',
      EditorOperation.exporting => 'Choose where to save the processed copy…',
      EditorOperation.deleting => 'Removing app-owned copies…',
      EditorOperation.openingBrowser => 'Opening iCloud Photos…',
      null => '',
    };
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void dismissMessage() {
    error = null;
    notice = null;
    _emit();
  }

  bool isBatchMode = false;

  void select(MediaSession? session) {
    if (busy || !ready) return;
    isBatchMode = false;
    selected = session;
    acknowledgedProcessingId = null;
    error = null;
    notice = null;
    _emit();
  }

  void startBatchEditing() {
    if (busy || !ready || batchSelection.isEmpty) return;
    isBatchMode = true;
    final targetId = batchSelection.first;
    selected = sessions.firstWhere(
      (s) => s.id == targetId,
      orElse: () => sessions.firstWhere(
        (s) => batchSelection.contains(s.id),
        orElse: () => sessions.first,
      ),
    );
    acknowledgedProcessingId = null;
    error = null;
    notice = null;
    _emit();
  }

  void exitBatchEditing() {
    if (busy || !ready) return;
    isBatchMode = false;
    selected = null;
    acknowledgedProcessingId = null;
    _emit();
  }

  void acknowledge(bool value) {
    if (busy) return;
    acknowledgedProcessingId = value ? selected?.processing?.id : null;
    _emit();
  }

  void _upsert(MediaSession session) {
    _sessions = [session, ..._sessions.where((item) => item.id != session.id)];
    selected = session;
  }

  Future<void> _run(
    EditorOperation next,
    Future<void> Function(int generation) action, {
    bool needsReady = true,
    bool reconcileOnFailure = false,
  }) async {
    if (busy || _disposed || (needsReady && !ready)) return;
    final generation = ++_generation;
    final selectedId = selected?.id;
    operation = next;
    error = null;
    notice = null;
    cancellationRequested = false;
    _emit();
    try {
      await action(generation);
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = readableError(failure);
        if (reconcileOnFailure) {
          acknowledgedProcessingId = null;
          try {
            final recovered = await bridge.listSessions();
            if (_current(generation)) {
              _sessions = recovered;
              final matches = recovered.where((item) => item.id == selectedId);
              selected = matches.isEmpty ? null : matches.first;
            }
          } catch (_) {
            if (_current(generation)) {
              // Keep the original operation error visible; stale rows must not remain exportable.
              capabilities = null;
              notice = 'Local history could not be refreshed. Retry startup before editing or exporting again.';
            }
          }
        }
      }
    } finally {
      if (!_disposed) {
        if (generation != _generation && ready) {
          try {
            final recovered = await bridge.listSessions();
            if (!_disposed) {
              _sessions = recovered;
              final selectedId = selected?.id;
              final matches = recovered.where((item) => item.id == selectedId);
              selected = matches.isEmpty ? null : matches.first;
              acknowledgedProcessingId = null;
              notice = 'Operation finished after cancellation was requested. Review any recovered copy before exporting.';
            }
          } catch (failure) {
            if (!_disposed) error = readableError(failure);
          }
        }
        operation = null;
        cancellationRequested = false;
        _emit();
      }
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> initialize() =>
      _run(EditorOperation.loading, (generation) async {
        final engine = await bridge.capabilities();
        final sessions = await bridge.listSessions();
        if (!_current(generation)) return;
        final state = await bridge.loadEditorState();
        if (!_current(generation)) return;
        if (state.isNotEmpty && state['schemaVersion'] != 1) {
          throw const FormatException('Incompatible editor state.');
        }
        _editorState = state;
        final storedPresets = state['presets'];
        presets = storedPresets is List
            ? storedPresets.map(SavedPreset.decode).toList()
            : [];
        final storedQueue = state['queue'];
        queue = storedQueue is List
            ? storedQueue
                  .map(QueueItem.decode)
                  .where((item) => sessions.any((s) => s.id == item.sessionId))
                  .toList()
            : [];
        for (final item in queue) {
          if (item.status == 'running') {
            item.status = 'interrupted';
            item.message = 'Interrupted. Retry to finish.';
          }
        }
        for (final item in queue.where((q) => q.status == 'completed')) {
          final output = sessions
              .firstWhere((s) => s.id == item.sessionId)
              .processing;
          if (output == null ||
              output.metadataPatch == null ||
              !output.metadataPatch!.equivalent(item.patch) ||
              output.integrity.hasMismatch) {
            item.status = 'interrupted';
            item.message =
                'The saved output no longer matches this batch plan. Retry.';
          }
        }
        batchSelection.clear();
        final storedSelection = state['selection'];
        if (storedSelection is List) {
          batchSelection.addAll(
            storedSelection.whereType<String>().where(
              (id) => sessions.any((s) => s.id == id),
            ),
          );
        }
        capabilities = engine;
        _sessions = sessions;
        selected = null;
      }, needsReady: false);

  Future<void> importMedia({required bool photos}) =>
      _run(EditorOperation.importing, (generation) async {
        final session = await bridge.importMedia(photos: photos);
        if (!_current(generation)) return;
        if (session != null) {
          _upsert(session);
          acknowledgedProcessingId = null;
        }
      });

  void toggleBatch(MediaSession session, bool selected) {
    if (busy) return;
    if (selected) {
      batchSelection.add(session.id);
    } else {
      batchSelection.remove(session.id);
    }
    _emit();
  }

  Future<void> importBatch({required bool photos}) =>
      _run(EditorOperation.importing, (generation) async {
        final result = await bridge.importBatch(photos: photos);
        if (!_current(generation)) return;
        batchSelection.clear();
        final incomingIds = result.sessions.map((s) => s.id).toSet();
        _sessions = [
          ...result.sessions,
          ..._sessions.where((item) => !incomingIds.contains(item.id)),
        ];
        for (final session in result.sessions) {
          batchSelection.add(session.id);
        }
        if (result.sessions.length > 1) {
          isBatchMode = true;
          selected = result.sessions.first;
        } else if (result.sessions.length == 1) {
          isBatchMode = false;
          selected = result.sessions.first;
        }
        if (result.errors.isNotEmpty) {
          notice =
              '${result.sessions.length} imported. ${result.errors.join('\n')}';
        } else if (result.sessions.length > 1) {
          notice = '${result.sessions.length} file(s) imported.';
        }
        await _persist();
      }, reconcileOnFailure: true);
  Future<void> savePreset(
    String name,
    MetadataPatch patch, {
    ProfileRecipe? recipe,
  }) => _run(EditorOperation.deleting, (_) async {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
    final preset = SavedPreset.decode({
      'schemaVersion': 1,
      'id': id,
      'name': name.trim(),
      'patch': patch.toMap(),
      if (recipe != null) 'recipe': recipe.toMap(),
    });
    final before = List<SavedPreset>.of(presets);
    presets = [...presets, preset];
    try {
      await _persist();
    } catch (_) {
      presets = before;
      rethrow;
    }
    notice = 'Preset saved.';
  });
  Future<void> deletePreset(SavedPreset preset) =>
      _run(EditorOperation.deleting, (_) async {
        final before = List<SavedPreset>.of(presets);
        presets = presets.where((p) => p.id != preset.id).toList();
        try {
          await _persist();
        } catch (_) {
          presets = before;
          rethrow;
        }
      });
  Future<void> importPreset() => _run(EditorOperation.importing, (_) async {
    final raw = await bridge.importPreset();
    if (raw == null) return;
    final preset = SavedPreset.decode(raw);
    final before = List<SavedPreset>.of(presets);
    presets = [...presets.where((p) => p.id != preset.id), preset];
    try {
      await _persist();
    } catch (_) {
      presets = before;
      rethrow;
    }
    notice = 'Preset imported.';
  });
  Future<void> exportPreset(SavedPreset preset) =>
      _run(EditorOperation.exporting, (_) async {
        await bridge.exportPreset(preset.toMap());
      });
  Future<void> verifyOriginal() => _run(EditorOperation.importing, (_) async {
    final source = selected;
    final output = source?.processing;
    if (source == null || output == null) return;
    final result = await bridge.verifyOriginal(source.id, output.id);
    if (result == null) {
      notice = 'Comparison canceled.';
      return;
    }
    notice = result['exactMatch'] == true
        ? 'The selected original exactly matches the processed file, byte for byte.'
        : 'The selected file differs from the processed file. Download the unmodified original for comparison.';
  });
  void _validateProcessed(
    MediaSession source,
    MetadataPatch patch,
    MediaSession result,
  ) {
    if (result.id != source.id ||
        result.processing == null ||
        result.processing!.metadataPatch == null ||
        !result.processing!.metadataPatch!.equivalent(patch)) {
      throw const FormatException(
        'Processed edit plan differs from the request.',
      );
    }
    // Exact typed readback and payload verification occur independently in Swift.
    // Dart must not approximate rational/date values from formatted inspection strings.
  }

  Future<void> processMetadata(MetadataPatch patch) async {
    final source = selected;
    if (source == null || busy || !ready) return;
    final invalid = patch.validate();
    if (invalid != null) {
      error = invalid;
      _emit();
      return;
    }
    final supported = capabilities!.fieldsFor(source.inspection.kind);
    if (patch.values.keys.any((k) => !supported.contains(k)) ||
        patch.removals.any((k) => !supported.contains(k))) {
      error = 'Some selected fields are unsupported for this format. Remove those changes first.';
      _emit();
      return;
    }
    acknowledgedProcessingId = null;
    _upsert(source.withoutOutput());
    await _run(EditorOperation.processing, (generation) async {
      final result = await bridge.processMetadata(source.id, patch);
      if (!_current(generation)) return;
      _validateProcessed(source, patch, result);
      _upsert(result);
      notice = result.processing!.integrity.hasMismatch
          ? 'A preservation check failed. Export is blocked.'
          : 'Processed copy ready.';
    }, reconcileOnFailure: true);
  }

  Future<void> processBatch(
    Map<String, MetadataPatch> patches, {
    bool retry = false,
  }) async {
    if (busy || !ready || patches.isEmpty) return;
    for (final entry in patches.entries) {
      final matches = sessions.where((s) => s.id == entry.key);
      final invalid = entry.value.validate();
      if (matches.isEmpty ||
          invalid != null ||
          entry.value.values.keys.any(
            (k) => !capabilities!
                .fieldsFor(matches.first.inspection.kind)
                .contains(k),
          ) ||
          entry.value.removals.any(
            (k) => !capabilities!
                .fieldsFor(matches.first.inspection.kind)
                .contains(k),
          )) {
        error = invalid ?? 'A batch field is unsupported.';
        _emit();
        return;
      }
    }
    await _run(EditorOperation.processing, (generation) async {
      if (!retry) {
        queue = patches.entries.map((e) => QueueItem(e.key, e.value)).toList();
      }
      await _persist();
      queueCompleted = 0;
      for (final item in queue) {
        if (!_current(generation)) break;
        if (item.status == 'completed') {
          queueCompleted++;
          continue;
        }
        item.status = 'running';
        item.message = null;
        await _persist();
        _emit();
        try {
          final source = sessions.firstWhere((s) => s.id == item.sessionId);
          _upsert(source.withoutOutput());
          final result = await bridge.processMetadata(
            item.sessionId,
            item.patch,
          );
          if (!_current(generation)) {
            item.status = 'interrupted';
            break;
          }
          _validateProcessed(source, item.patch, result);
          _upsert(result);
          item.status = result.processing!.integrity.hasMismatch
              ? 'failed'
              : 'completed';
          if (item.status == 'failed') {
            item.message = 'Preservation check failed. Export blocked.';
          }
        } catch (failure) {
          item.status = 'failed';
          item.message = readableError(failure);
          if (_current(generation)) {
            try {
              final recovered = await bridge.listSessions();
              if (_current(generation)) {
                _sessions = recovered;
                selected = null;
                acknowledgedProcessingId = null;
              }
            } catch (_) {
              if (_current(generation)) {
                capabilities = null;
                error = 'Local history could not be refreshed. Restart before exporting.';
              }
            }
          }
        }
        queueCompleted++;
        await _persist();
        _emit();
        if (!ready) break;
      }
      if (!_current(generation)) {
        for (final item in queue) {
          if (item.status == 'pending' || item.status == 'running') {
            item.status = 'interrupted';
          }
        }
      }
      await _persist();
      if (_current(generation)) {
        selected = null;
        isBatchMode = false;
        notice =
            'Batch finished: ${queue.where((q) => q.status == "completed").length}/${queue.length} ready.';
      }
    }, reconcileOnFailure: true);
  }

  int get queueTotal => queue.length;
  int get queueCompletedCount =>
      queue.where((q) => q.status == 'completed').length;
  int get queueFailedCount => queue
      .where((q) => q.status == 'failed' || q.status == 'interrupted')
      .length;
  int get queueRunningCount => queue.where((q) => q.status == 'running').length;

  Future<void> retryBatch() => processBatch({
    for (final item in queue)
      if (item.status != 'completed') item.sessionId: item.patch,
  }, retry: true);
  Future<void> exportSelectedBatch({
    bool acknowledgeIncomplete = false,
    bool onlyReady = false,
  }) => _run(EditorOperation.exporting, (_) async {
    final completedIds = queue
        .where((q) => q.status == 'completed')
        .map((q) => q.sessionId)
        .toSet();
    final chosen = onlyReady
        ? sessions.where((s) => completedIds.contains(s.id)).toList()
        : sessions.where((s) => batchSelection.contains(s.id)).toList();
    final targets = onlyReady
        ? chosen
              .where(
                (s) =>
                    s.processing != null &&
                    !s.processing!.integrity.hasMismatch &&
                    (!s.processing!.integrity.needsAcknowledgment ||
                        acknowledgeIncomplete),
              )
              .toList()
        : chosen;
    if (targets.isEmpty ||
        (!onlyReady &&
            chosen.any(
              (s) =>
                  s.processing == null ||
                  s.processing!.integrity.hasMismatch ||
                  (s.processing!.integrity.needsAcknowledgment &&
                      !acknowledgeIncomplete),
            ))) {
      throw const FormatException(
        'The batch contains unprocessed or unqualified copies.',
      );
    }
    final completed = await bridge.exportBatch(
      targets
          .map(
            (s) => <String, Object?>{
              'sessionId': s.id,
              'processingId': s.processing!.id,
              'acknowledgeIncomplete': acknowledgeIncomplete,
            },
          )
          .toList(),
    );
    notice = completed
        ? 'Copies saved to Files. Upload in Safari to finish.'
        : 'Export canceled.';
  }, reconcileOnFailure: true);

  Future<void> shareSelectedBatch({
    bool acknowledgeIncomplete = false,
    bool onlyReady = false,
  }) => _run(EditorOperation.exporting, (_) async {
    final completedIds = queue
        .where((q) => q.status == 'completed')
        .map((q) => q.sessionId)
        .toSet();
    final chosen = onlyReady
        ? sessions.where((s) => completedIds.contains(s.id)).toList()
        : sessions.where((s) => batchSelection.contains(s.id)).toList();
    final targets = onlyReady
        ? chosen
              .where(
                (s) =>
                    s.processing != null &&
                    !s.processing!.integrity.hasMismatch &&
                    (!s.processing!.integrity.needsAcknowledgment ||
                        acknowledgeIncomplete),
              )
              .toList()
        : chosen;
    if (targets.isEmpty ||
        (!onlyReady &&
            chosen.any(
              (s) =>
                  s.processing == null ||
                  s.processing!.integrity.hasMismatch ||
                  (s.processing!.integrity.needsAcknowledgment &&
                      !acknowledgeIncomplete),
            ))) {
      throw const FormatException(
        'The batch contains unprocessed or unqualified copies.',
      );
    }
    final completed = await bridge.shareBatch(
      targets
          .map(
            (s) => <String, Object?>{
              'sessionId': s.id,
              'processingId': s.processing!.id,
              'acknowledgeIncomplete': acknowledgeIncomplete,
            },
          )
          .toList(),
    );
    notice = completed ? 'Batch shared.' : 'Share canceled.';
  }, reconcileOnFailure: true);
  Future<void> process(CameraPatch patch) async {
    final source = selected;
    if (busy || !ready || source == null) return;
    final invalid = patch.validate(source.inspection.kind);
    if (invalid != null) {
      error = invalid;
      _emit();
      return;
    }
    acknowledgedProcessingId = null;
    _upsert(source.withoutOutput());
    await _run(EditorOperation.processing, (generation) async {
      final result = await bridge.process(source.id, patch);
      if (!_current(generation)) return;
      if (result.id != source.id || result.processing == null) {
        throw const FormatException('Invalid processed session.');
      }
      final frozen = result.processing!;
      if (frozen.patch.make != patch.make ||
          frozen.patch.model != patch.model ||
          frozen.patch.lens != patch.lens ||
          frozen.inspection.metadata['make'] != patch.make ||
          frozen.inspection.metadata['model'] != patch.model ||
          (patch.lens != null &&
              frozen.inspection.metadata['lens'] != patch.lens)) {
        throw const FormatException(
          'Camera readback does not match the requested edit.',
        );
      }
      _upsert(result);
      notice = result.processing!.integrity.hasMismatch
          ? 'A preservation check failed. Export is blocked.'
          : 'Camera fields were read back. Review the preservation checks before exporting.';
    });
  }

  Future<void> exportFiles() async {
    if (!canExport) return;
    final source = selected!;
    final processing = source.processing!;
    final acknowledged = acknowledgedProcessingId == processing.id;
    await _run(EditorOperation.exporting, (generation) async {
      final completed = await bridge.exportFiles(
        source.id,
        processing.id,
        acknowledged,
      );
      if (!_current(generation)) return;
      notice = completed
          ? 'Copy saved to Files. Upload it in Safari to finish the Photos workflow.'
          : 'Export canceled. Your processed copy is still available here.';
    }, reconcileOnFailure: true);
  }

  Future<void> shareFiles() async {
    if (!canExport) return;
    final source = selected!;
    final processing = source.processing!;
    final acknowledged = acknowledgedProcessingId == processing.id;
    await _run(EditorOperation.exporting, (generation) async {
      final completed = await bridge.shareFiles(
        source.id,
        processing.id,
        acknowledged,
      );
      if (!_current(generation)) return;
      notice = completed
          ? 'Share sheet completed.'
          : 'Share canceled. Your processed copy is still available here.';
    }, reconcileOnFailure: true);
  }

  Future<void> cancel() async {
    if (!busy ||
        cancellationRequested ||
        operation == EditorOperation.loading ||
        operation == EditorOperation.deleting ||
        operation == EditorOperation.openingBrowser) {
      return;
    }
    cancellationRequested = true;
    ++_generation; // Native work can finish later; its result must not select or certify a copy.
    _emit();
    try {
      await bridge.cancel();
      if (!_disposed && cancellationRequested) {
        notice = 'Cancellation requested. Your original is unchanged.';
      }
    } catch (failure) {
      if (!_disposed && cancellationRequested) error = readableError(failure);
    }
    _emit();
  }

  Future<void> delete(MediaSession session) =>
      _run(EditorOperation.deleting, (generation) async {
        await bridge.deleteSession(session.id);
        if (!_current(generation)) return;
        _sessions = _sessions.where((item) => item.id != session.id).toList();
        if (selected?.id == session.id) selected = null;
        batchSelection.remove(session.id);
        queue.removeWhere((q) => q.sessionId == session.id);
        await _persist();
        acknowledgedProcessingId = null;
        notice = 'App-owned copies removed. Photos and provider originals are unchanged.';
      }, reconcileOnFailure: true);
  Future<void> clear() => _run(EditorOperation.deleting, (generation) async {
    await bridge.clearSessions();
    if (!_current(generation)) return;
    _sessions = const [];
    selected = null;
    queue = [];
    batchSelection.clear();
    await _persist();
    acknowledgedProcessingId = null;
    notice =
        'Local projects cleared. Photos and provider originals are unchanged.';
  }, reconcileOnFailure: true);
  Future<void> openICloud() =>
      _run(EditorOperation.openingBrowser, (_) => bridge.openICloud());
  Future<void> openUrl(String url) =>
      _run(EditorOperation.openingBrowser, (_) => bridge.openUrl(url));
  Future<void> openWebsite() => openUrl(AppBrand.websiteUrl);
  Future<void> clearCache() => clear();
  Future<void> resetPresets() async {
    final before = List<SavedPreset>.of(presets);
    presets = const [];
    try {
      await _persist();
      notice = 'Saved camera presets reset.';
      notifyListeners();
    } catch (error) {
      presets = before;
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}

class QueueItem {
  QueueItem(
    this.sessionId,
    this.patch, {
    this.status = 'pending',
    this.message,
  });
  final String sessionId;
  final MetadataPatch patch;
  String status;
  String? message;
  Map<String, Object?> toMap() => {
    'sessionId': sessionId,
    'patch': patch.toMap(),
    'status': status,
    'message': message,
  };
  factory QueueItem.decode(Object? raw) {
    final m = objectMap(raw);
    final status = requiredString(m, 'status');
    if (![
          'pending',
          'running',
          'completed',
          'failed',
          'interrupted',
        ].contains(status) ||
        (m['message'] != null && m['message'] is! String)) {
      throw const FormatException('Invalid batch queue.');
    }
    return QueueItem(
      identifier(m, 'sessionId'),
      MetadataPatch.decode(m['patch']),
      status: status,
      message: m['message'] as String?,
    );
  }
}
