import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_brand.dart';
import 'camera_profiles.dart';
import 'metadata_patch.dart';

import 'media_bridge.dart';
import 'media_models.dart';

enum EditorOperation {
  loading,
  importing,
  preparingCopies,
  processing,
  exporting,
  deleting,
  openingBrowser,
  openingWebsite,
  openingEmail,
}

class EditorController extends ChangeNotifier {
  EditorController(this.bridge);
  final MediaBridge bridge;
  List<SavedPreset> presets = [];
  final Set<String> batchSelection = {};
  List<QueueItem> queue = [];
  String? selectedBrand;
  String? selectedProfileId;
  String? selectedCameraId;
  String? lastErrorCode;
  String? lastErrorMessage;
  DateTime? lastErrorTime;
  String? statePersistenceError;
  String appearance = 'system';
  int _appearanceRevision = 0;
  bool _deferredAppearancePersistence = false;
  bool _stateRestored = false;
  Map<String, Object?> _editorState = {};
  int queueCompleted = 0;
  Future<void> _persistenceTail = Future<void>.value();
  int _persistenceRevision = 0;
  int _pendingPersistenceWrites = 0;
  bool _deferredErrorHistoryPersistence = false;

  static const _errorHistoryKeys = [
    'lastErrorCode',
    'lastErrorMessage',
    'lastErrorTime',
  ];

  void _restorePersistedErrorHistory(Map<String, Object?> state) {
    for (final key in _errorHistoryKeys) {
      if (_editorState.containsKey(key)) {
        state[key] = _editorState[key];
      } else {
        state.remove(key);
      }
    }
  }

  Future<void> _persist() async {
    final state = <String, Object?>{
      ..._editorState,
      'schemaVersion': 1,
      'presets': _stateRestored
          ? presets.map((p) => p.toMap()).toList()
          : _editorState['presets'] ?? [],
      'queue': _stateRestored
          ? queue.map((q) => q.toMap()).toList()
          : _editorState['queue'] ?? [],
      'selection': _stateRestored
          ? batchSelection.toList()
          : _editorState['selection'] ?? [],
      'appearance': appearance,
    };
    if (_stateRestored && selectedBrand != null) {
      state['selectedBrand'] = selectedBrand;
    } else if (_stateRestored) {
      state.remove('selectedBrand');
    }
    if (_stateRestored && selectedProfileId != null) {
      state['selectedProfileId'] = selectedProfileId;
    } else if (_stateRestored) {
      state.remove('selectedProfileId');
    }
    if (_stateRestored && selectedCameraId != null) {
      state['selectedCameraId'] = selectedCameraId;
    } else if (_stateRestored) {
      state.remove('selectedCameraId');
    }
    if (lastErrorCode != null) {
      state['lastErrorCode'] = lastErrorCode;
    } else {
      state.remove('lastErrorCode');
    }
    if (lastErrorMessage != null) {
      state['lastErrorMessage'] = lastErrorMessage;
    } else {
      state.remove('lastErrorMessage');
    }
    if (lastErrorTime != null) {
      state['lastErrorTime'] = lastErrorTime!.toIso8601String();
    } else {
      state.remove('lastErrorTime');
    }
    // NativeMediaBridge serializes state saves with media operations. History
    // changes made while busy are deferred until the operation releases that
    // gate. Internal queue checkpoints can still persist, but must not sneak
    // the deferred history update into the native channel.
    if (busy && _deferredErrorHistoryPersistence) {
      _restorePersistedErrorHistory(state);
    }
    if (busy && _deferredAppearancePersistence) {
      state['appearance'] = _editorState['appearance'] ?? 'system';
    }
    final revision = ++_persistenceRevision;
    _pendingPersistenceWrites++;
    final write = _persistenceTail.then((_) async {
      try {
        await bridge.saveEditorState(state);
        _editorState = state;
        if (revision == _persistenceRevision && statePersistenceError != null) {
          statePersistenceError = null;
          if (!_disposed) _emit();
        }
      } finally {
        _pendingPersistenceWrites--;
      }
    });
    // Keep later writes runnable after a failed save, while returning the
    // original failure to callers that await this persistence operation.
    _persistenceTail = write.then<void>((_) {}, onError: (Object _) {});
    try {
      await write;
    } catch (failure) {
      if (revision == _persistenceRevision) {
        statePersistenceError = readableError(failure);
      }
      rethrow;
    }
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
      EditorOperation.preparingCopies => 'Preparing names for your copies…',
      EditorOperation.processing =>
        'Writing metadata and checking media integrity…',
      EditorOperation.exporting => 'Choose where to save the processed copy…',
      EditorOperation.deleting => 'Removing app-owned copies…',
      EditorOperation.openingBrowser => 'Opening iCloud Photos…',
      EditorOperation.openingWebsite => 'Opening the Zlarp website…',
      EditorOperation.openingEmail => 'Opening your email app…',
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

  static String classifyErrorCode(String message) {
    final text = message.toLowerCase();
    if (text.contains('date') ||
        text.contains('datetimeoriginal') ||
        text.contains('iso 8601') ||
        text.contains('timestamp') ||
        text.contains('time zone') ||
        text.contains('offsettime') ||
        text.contains('err_date_fmt')) {
      return 'ERR_DATE_FMT';
    }
    if (text.contains('latitude') ||
        text.contains('longitude') ||
        text.contains('altitude') ||
        text.contains('direction') ||
        text.contains('coordinate') ||
        text.contains('err_gps_bounds')) {
      return 'ERR_GPS_BOUNDS';
    }
    if (text.contains('integrity') ||
        text.contains('retained embedded metadata') ||
        text.contains('verification failed') ||
        text.contains('err_media_integrity')) {
      return 'ERR_MEDIA_INTEGRITY';
    }
    if (text.contains('cannot be changed and removed together') ||
        text.contains('conflict') ||
        text.contains('ascii') ||
        text.contains('non-ascii') ||
        text.contains('err_field_conflict')) {
      return 'ERR_FIELD_CONFLICT';
    }
    if (text.contains('unprocessed') ||
        text.contains('no processed copies') ||
        text.contains('ready') ||
        text.contains('select and process') ||
        text.contains('err_export_unready')) {
      return 'ERR_EXPORT_UNREADY';
    }
    if (text.contains('photos access') ||
        text.contains('photos permission') ||
        text.contains('permission') ||
        text.contains('err_photos_access')) {
      return 'ERR_PHOTOS_ACCESS';
    }
    if (text.contains('storage') ||
        text.contains('space') ||
        text.contains('quota') ||
        text.contains('disk') ||
        text.contains('err_storage_full')) {
      return 'ERR_STORAGE_FULL';
    }
    if (text.contains('unsupported') ||
        text.contains('malformed') ||
        text.contains('codec') ||
        text.contains('format') ||
        text.contains('err_unsupported_media')) {
      return 'ERR_UNSUPPORTED_MEDIA';
    }
    return 'ERR_PROCESSING';
  }

  static String classifyFailureCode(Object failure, String message) {
    if (failure is PlatformException) {
      return switch (failure.code) {
        'permission' => 'ERR_PHOTOS_ACCESS',
        'storage' => 'ERR_STORAGE_FULL',
        'unsupported' || 'malformed' => 'ERR_UNSUPPORTED_MEDIA',
        'readback' || 'integrity' => 'ERR_MEDIA_INTEGRITY',
        'not_found' ||
        'processing' ||
        'invalid_argument' ||
        'busy' ||
        'canceled' => 'ERR_PROCESSING',
        _ => classifyErrorCode(message),
      };
    }
    return classifyErrorCode(message);
  }

  void recordError(String message, {String? code}) {
    lastErrorCode = code ?? classifyErrorCode(message);
    lastErrorMessage = message;
    lastErrorTime = DateTime.now();
    _scheduleErrorHistoryPersistence();
    _emit();
  }

  void clearLastError() {
    lastErrorCode = null;
    lastErrorMessage = null;
    lastErrorTime = null;
    _scheduleErrorHistoryPersistence();
    _emit();
  }

  void _scheduleErrorHistoryPersistence() {
    if (busy) {
      _deferredErrorHistoryPersistence = true;
      return;
    }
    unawaited(
      _persist().catchError((_) {
        if (!_disposed) _emit();
      }),
    );
  }

  void _flushDeferredErrorHistoryPersistence() {
    if (!_deferredErrorHistoryPersistence || busy || _disposed) return;
    _deferredErrorHistoryPersistence = false;
    unawaited(
      _persist().catchError((_) {
        if (!_disposed) _emit();
      }),
    );
  }

  Future<void> setAppearance(String value) async {
    if (_disposed || !const ['system', 'light', 'dark'].contains(value)) return;
    appearance = value;
    _appearanceRevision++;
    _emit();
    if (busy) {
      _deferredAppearancePersistence = true;
      return;
    }
    try {
      await _persist();
    } catch (_) {
      // Keep the chosen appearance usable and expose the existing storage
      // warning when the preference cannot be remembered.
      if (!_disposed) _emit();
    }
  }

  void _flushDeferredAppearancePersistence() {
    if (!_deferredAppearancePersistence || busy || _disposed) return;
    _deferredAppearancePersistence = false;
    unawaited(
      _persist().catchError((_) {
        if (!_disposed) _emit();
      }),
    );
  }

  bool isBatchMode = false;
  int batchEditorRevision = 0;

  /// Explicit recovery opens the queue's results instead of reusing a draft.
  void resumeStoredBatch() {
    if (busy || !ready) return;
    final validIds = sessions.map((session) => session.id).toSet();
    final queuedIds = queue
        .map((item) => item.sessionId)
        .where(validIds.contains)
        .toSet();
    if (queuedIds.isEmpty) return;
    batchSelection
      ..clear()
      ..addAll(queuedIds);
    batchEditorRevision++;
    startBatchEditing();
  }

  void select(MediaSession? session) {
    if (busy || !ready) return;
    isBatchMode = false;
    selected = session;
    acknowledgedProcessingId = null;
    error = null;
    notice = null;
    _emit();
  }

  void _normalizeBatchState() {
    final validIds = sessions.map((session) => session.id).toSet();
    batchSelection.removeWhere((id) => !validIds.contains(id));
    queue.removeWhere((item) => !validIds.contains(item.sessionId));

    if (selected != null && !validIds.contains(selected!.id)) {
      selected = null;
    }
    if (batchSelection.isEmpty) {
      isBatchMode = false;
      _reconcileCompletedQueueRows();
      return;
    }
    if (isBatchMode &&
        (selected == null || !batchSelection.contains(selected!.id))) {
      selected = sessions
          .where((session) => batchSelection.contains(session.id))
          .firstOrNull;
      if (selected == null) isBatchMode = false;
    }
    _reconcileCompletedQueueRows();
  }

  void startBatchEditing() {
    if (busy || !ready) return;
    _normalizeBatchState();
    if (batchSelection.isEmpty) return;
    isBatchMode = true;
    selected = sessions
        .where((session) => batchSelection.contains(session.id))
        .firstOrNull;
    if (selected == null) {
      isBatchMode = false;
      return;
    }
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
    _normalizeBatchState();
  }

  bool _reconcileCompletedQueueRows() {
    var changed = false;
    for (final item in queue.where((row) => row.status == 'completed')) {
      final session = sessions
          .where((candidate) => candidate.id == item.sessionId)
          .firstOrNull;
      final output = session?.processing;
      if (output == null ||
          output.metadataPatch == null ||
          !output.metadataPatch!.equivalent(item.patch) ||
          output.integrity.hasMismatch) {
        item.status = 'interrupted';
        item.message =
            'The saved output no longer matches this batch plan. Retry.';
        changed = true;
      }
    }
    return changed;
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
      // Complete idle state writes before entering the native bridge. Its
      // state-save and media-operation methods share a serialized channel.
      if (_pendingPersistenceWrites > 0) await _persistenceTail;
      if (!_current(generation)) return;
      await action(generation);
    } catch (failure) {
      if (!_disposed && generation == _generation) {
        error = readableError(failure);
        recordError(error!, code: classifyFailureCode(failure, error!));
        if (reconcileOnFailure) {
          acknowledgedProcessingId = null;
          try {
            final recovered = await bridge.listSessions();
            if (_current(generation)) {
              _sessions = recovered;
              final matches = recovered.where((item) => item.id == selectedId);
              selected = matches.isEmpty ? null : matches.first;
              _normalizeBatchState();
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
              _normalizeBatchState();
              acknowledgedProcessingId = null;
              notice = 'Operation finished after cancellation was requested. Review any recovered copy before exporting.';
            }
          } catch (failure) {
            if (!_disposed) {
              // Native work may have committed after cancellation. Without a
              // fresh history snapshot, the cached session can point at an
              // output token that no longer matches native state. Disable all
              // editing/export actions until startup reconciles the journal.
              capabilities = null;
              error = readableError(failure);
              recordError(error!, code: classifyFailureCode(failure, error!));
              notice = 'Local history could not be refreshed after cancellation. Retry startup before editing or exporting.';
            }
          }
        }
        operation = null;
        cancellationRequested = false;
        _emit();
        _flushDeferredErrorHistoryPersistence();
        _flushDeferredAppearancePersistence();
      }
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<Map<String, String>> reserveOutputNames(
    List<String> sessionIds,
  ) async {
    var names = <String, String>{};
    await _run(EditorOperation.preparingCopies, (generation) async {
      if (sessionIds.isEmpty ||
          sessionIds.length > 50 ||
          sessionIds.toSet().length != sessionIds.length ||
          sessionIds.any((id) => !_sessions.any((s) => s.id == id))) {
        throw const FormatException(
          'Select existing files to prepare their copies.',
        );
      }
      final reserved = await bridge.reserveOutputNames(List.of(sessionIds));
      if (reserved.length != sessionIds.length ||
          reserved.values.toSet().length != reserved.length) {
        throw const FormatException('Invalid output name reservation.');
      }
      for (final id in sessionIds) {
        final kind = _sessions.firstWhere((s) => s.id == id).inspection.kind;
        final extensions = switch (kind) {
          MediaKind.jpeg => ['JPG', 'JPEG'],
          MediaKind.heic => ['HEIC', 'HEIF'],
          _ => [kind.name.toUpperCase()],
        };
        final name = reserved[id];
        if (name == null ||
            !RegExp(r'^IMG_[0-9]{4}\.(JPG|JPEG|HEIC|HEIF|PNG|MP4|MOV)$')
                .hasMatch(name) ||
            !extensions.any((ext) => name.endsWith('.$ext'))) {
          throw const FormatException('Invalid output name reservation.');
        }
      }
      if (_current(generation)) names = reserved;
    });
    return names;
  }

  Future<void> initialize() => _run(EditorOperation.loading, (
    generation,
  ) async {
    final appearanceRevision = _appearanceRevision;
    var state = await bridge.loadEditorState();
    if (!_current(generation)) return;
    if (state.isNotEmpty && state['schemaVersion'] != 1) {
      throw const FormatException('Incompatible editor state.');
    }
    _editorState = state;
    if (appearanceRevision == _appearanceRevision) {
      final storedAppearance = state['appearance'];
      appearance = const ['system', 'light', 'dark'].contains(storedAppearance)
          ? storedAppearance as String
          : 'system';
      _emit();
    }
    final engine = await bridge.capabilities();
    final sessions = await bridge.listSessions();
    if (!_current(generation)) return;
    // Read the complete journal after startup as before. An idle history write
    // may have finished while the engine was recovering; the early read is
    // only needed to make the stored appearance available during that wait.
    state = await bridge.loadEditorState();
    if (!_current(generation)) return;
    if (state.isNotEmpty && state['schemaVersion'] != 1) {
      throw const FormatException('Incompatible editor state.');
    }
    _editorState = state;
    final storedBrand = state['selectedBrand'];
    if (storedBrand is String) selectedBrand = storedBrand;
    final storedProfileId = state['selectedProfileId'];
    if (storedProfileId is String) selectedProfileId = storedProfileId;
    final storedCameraId = state['selectedCameraId'];
    if (storedCameraId is String) selectedCameraId = storedCameraId;
    final storedErrorCode = state['lastErrorCode'];
    if (storedErrorCode is String) lastErrorCode = storedErrorCode;
    final storedErrorMessage = state['lastErrorMessage'];
    if (storedErrorMessage is String) lastErrorMessage = storedErrorMessage;
    final storedErrorTime = state['lastErrorTime'];
    if (storedErrorTime is String) {
      lastErrorTime = DateTime.tryParse(storedErrorTime);
    }
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
    isBatchMode = false;
    _normalizeBatchState();
    _stateRestored = true;
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
        } else {
          isBatchMode = false;
          selected = null;
        }
        _normalizeBatchState();
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
    final wasBatchMode = isBatchMode;
    final priorSelectionId = selected?.id;
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
      // Per-item reconciliation may prune rows whose sessions were removed
      // natively. Iterate a snapshot and skip any rows no longer in the live
      // queue so reconciliation cannot mutate this active iteration.
      for (final item in List<QueueItem>.of(queue)) {
        if (!queue.contains(item)) continue;
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
                _normalizeBatchState();
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
        final previousSelection = sessions.where(
          (session) => session.id == priorSelectionId,
        );
        selected = previousSelection.isEmpty ? null : previousSelection.first;
        isBatchMode = wasBatchMode;
        _normalizeBatchState();
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
    if (_reconcileCompletedQueueRows()) await _persist();
    final completedIds = queue
        .where((q) => q.status == 'completed')
        .map((q) => q.sessionId)
        .toSet();
    final chosen = onlyReady
        ? sessions.where((s) => completedIds.contains(s.id)).toList()
        : sessions.where((s) => batchSelection.contains(s.id)).toList();
    final readyTargets = chosen
        .where(
          (s) =>
              s.processing != null &&
              !s.processing!.integrity.hasMismatch &&
              (!s.processing!.integrity.needsAcknowledgment ||
                  acknowledgeIncomplete),
        )
        .toList();
    if (readyTargets.isEmpty) {
      throw const FormatException(
        'No processed copies are ready for export. Process files first.',
      );
    }
    if (!onlyReady && readyTargets.length < chosen.length) {
      throw const FormatException(
        'Selected files contain unprocessed copies. Process them before exporting.',
      );
    }
    final targets = onlyReady ? readyTargets : chosen;
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
    if (_reconcileCompletedQueueRows()) await _persist();
    final completedIds = queue
        .where((q) => q.status == 'completed')
        .map((q) => q.sessionId)
        .toSet();
    final chosen = onlyReady
        ? sessions.where((s) => completedIds.contains(s.id)).toList()
        : sessions.where((s) => batchSelection.contains(s.id)).toList();
    final readyTargets = chosen
        .where(
          (s) =>
              s.processing != null &&
              !s.processing!.integrity.hasMismatch &&
              (!s.processing!.integrity.needsAcknowledgment ||
                  acknowledgeIncomplete),
        )
        .toList();
    if (readyTargets.isEmpty) {
      throw const FormatException(
        'No processed copies are ready to share. Process files first.',
      );
    }
    if (!onlyReady && readyTargets.length < chosen.length) {
      throw const FormatException(
        'Selected files contain unprocessed copies. Process them before sharing.',
      );
    }
    final targets = onlyReady ? readyTargets : chosen;
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
        operation == EditorOperation.preparingCopies ||
        operation == EditorOperation.deleting ||
        operation == EditorOperation.openingBrowser ||
        operation == EditorOperation.openingWebsite ||
        operation == EditorOperation.openingEmail) {
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
        _normalizeBatchState();
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
    isBatchMode = false;
    _normalizeBatchState();
    await _persist();
    acknowledgedProcessingId = null;
    notice =
        'Local projects cleared. Photos and provider originals are unchanged.';
  }, reconcileOnFailure: true);
  Future<void> openICloud() => _run(
    EditorOperation.openingBrowser,
    (_) => bridge.openICloud(),
    needsReady: false,
  );
  Future<void> openUrl(String url) =>
      _run(EditorOperation.openingBrowser, (_) => bridge.openUrl(url));
  Future<void> openWebsite() => _run(
    EditorOperation.openingWebsite,
    (_) => bridge.openUrl(AppBrand.websiteUrl),
    needsReady: false,
  );
  Future<void> openSupportEmail() =>
      _run(EditorOperation.openingEmail, (generation) async {
        await bridge.openSupportEmail();
        if (_current(generation)) {
          notice = 'Continue in your email app to send your message.';
        }
      }, needsReady: false);
  Future<Map<String, double>?> pickLocation({
    double? latitude,
    double? longitude,
  }) async {
    if (busy || _disposed) return null;
    try {
      return await bridge.openLocationPicker(
        latitude: latitude,
        longitude: longitude,
      );
    } catch (failure) {
      if (!_disposed) {
        error = readableError(failure);
        _emit();
      }
      return null;
    }
  }

  Future<void> clearCache() => clear();

  Future<void> rememberSelectedProfile({
    String? brand,
    String? profileId,
    String? cameraId,
  }) async {
    selectedBrand = brand;
    selectedProfileId = profileId;
    selectedCameraId = cameraId;
    notifyListeners();
    try {
      await _persist();
    } catch (failure) {
      // Profile selection is also invoked from UI callbacks that intentionally
      // do not await persistence. Surface storage failures here so they cannot
      // become unhandled async errors or silently look like a saved preference.
      recordError(readableError(failure));
    }
  }

  Future<Map<String, String>?> getHostDevice() => bridge.getHostDevice();

  Future<void> matchHostDevice() async {
    try {
      final host = await getHostDevice();
      if (host != null && host['profileId'] != null) {
        await rememberSelectedProfile(
          brand: host['brand'] ?? 'Apple',
          profileId: host['profileId'],
          cameraId: 'main',
        );
        notice = 'Matched device: ${host['model'] ?? 'iPhone'}';
      }
    } catch (_) {}
  }

  Future<void> resetPresets() => _run(EditorOperation.deleting, (_) async {
    final before = List<SavedPreset>.of(presets);
    final beforeBrand = selectedBrand;
    final beforeProfileId = selectedProfileId;
    final beforeCameraId = selectedCameraId;
    presets = const [];
    selectedBrand = null;
    selectedProfileId = null;
    selectedCameraId = null;
    try {
      await _persist();
      notice = 'Saved camera presets reset.';
    } catch (error) {
      presets = before;
      selectedBrand = beforeBrand;
      selectedProfileId = beforeProfileId;
      selectedCameraId = beforeCameraId;
      rethrow;
    }
  });

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
