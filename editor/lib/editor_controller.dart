import 'package:flutter/foundation.dart';

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

  void select(MediaSession? session) {
    if (busy || !ready) return;
    selected = session;
    acknowledgedProcessingId = null;
    error = null;
    notice = null;
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
        acknowledgedProcessingId = null;
        notice = 'App-owned copies removed. Photos and provider originals are unchanged.';
      }, reconcileOnFailure: true);
  Future<void> clear() => _run(EditorOperation.deleting, (generation) async {
    await bridge.clearSessions();
    if (!_current(generation)) return;
    _sessions = const [];
    selected = null;
    acknowledgedProcessingId = null;
    notice =
        'Local projects cleared. Photos and provider originals are unchanged.';
  }, reconcileOnFailure: true);
  Future<void> openICloud() =>
      _run(EditorOperation.openingBrowser, (_) => bridge.openICloud());

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
