import 'dart:async';

import 'package:metadata_editor/media_bridge.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_patch.dart';

const sourceId = '00000000-0000-4000-8000-000000000001';
const outputId = '00000000-0000-4000-8000-000000000002';
const nextOutputId = '00000000-0000-4000-8000-000000000003';

MediaSession fixture({
  MediaKind kind = MediaKind.heic,
  String id = sourceId,
  IntegrityStatus? status,
  String processingId = outputId,
  CameraPatch patch = const CameraPatch(
    make: 'Test Make',
    model: 'Test Camera',
  ),
  bool failedCheck = false,
}) {
  const metadata = {
    'make': 'Original Make',
    'model': 'Original Camera',
    'lens': 'Original Lens',
  };
  MediaInspection inspection(Map<String, String> camera) => MediaInspection(
    kind: kind,
    byteCount: 4096,
    metadata: camera,
    structure: const {'width': '120', 'height': '160'},
    notes: const [],
  );
  return MediaSession(
    id: id,
    displayName: 'controlled.${kind.name}',
    origin: 'Files',
    createdAt: DateTime.utc(2026, 10, 8),
    inspection: inspection(metadata),
    notes: const ['Immutable original copy.'],
    details: const {'ISO': '100'},
    processing: status == null
        ? null
        : Processing(
            id: processingId,
            createdAt: DateTime.utc(2026, 10, 8),
            patch: patch,
            inspection: inspection({
              'make': patch.make,
              'model': patch.model,
              'lens': patch.lens ?? 'Original Lens',
            }),
            integrity: IntegrityReport(
              status,
              [
                IntegrityCheck(
                  'Compressed media',
                  failedCheck ? 'failed' : 'passed',
                  failedCheck
                      ? 'Payload differs.'
                      : 'Encoded item hashes match.',
                ),
              ],
              status == IntegrityStatus.incomplete
                  ? ['Opaque metadata semantics are not qualified.']
                  : [],
            ),
          ),
  );
}

Map<String, Object?> inspectionMap({String kind = 'jpeg'}) => {
  'kind': kind,
  'byteCount': 4096,
  'metadata': {'make': 'Original Make', 'model': 'Original Camera'},
  'structure': {'width': '120'},
  'notes': <String>[],
};

Map<String, Object?> sessionMap() => {
  'id': sourceId,
  'displayName': 'controlled.jpg',
  'origin': 'Files',
  'createdAt': '2026-10-08T12:00:00Z',
  'inspection': inspectionMap(),
  'notes': <String>[],
};

class FakeMediaBridge implements MediaBridge {
  List<MediaSession> sessions = [];
  MediaSession? importResult = fixture();
  Completer<MediaSession?>? pendingImport;
  Completer<MediaSession>? pendingProcess;
  Completer<bool>? pendingExport;
  Object? importError;
  Object? processError;
  Object? startupError;
  Object? historyError;
  Object? deleteAfterCommitError;
  Object? clearAfterCommitError;
  Object? exportError;
  List<MediaSession>? correctedExportSessions;
  IntegrityStatus nextStatus = IntegrityStatus.incomplete;
  int imports = 0;
  int processes = 0;
  int exports = 0;
  int cancels = 0;
  int opens = 0;
  String nextProcessingId = outputId;
  String? exportedProcessingId;
  bool? exportedAcknowledgment;
  CameraPatch? receivedPatch;
  final deletedIds = <String>[];
  @override
  Future<MediaCapabilities> capabilities() async {
    if (startupError != null) throw startupError!;
    return MediaCapabilities(
      ['jpeg', 'heic', 'png', 'mp4', 'mov'],
      metadataFields.map((f) => f.key).toList(),
      'provisional',
    );
  }

  @override
  Future<List<MediaSession>> listSessions() async {
    if (historyError != null) throw historyError!;
    return List.of(sessions);
  }

  @override
  Future<MediaSession?> importMedia({required bool photos}) async {
    imports++;
    if (importError != null) throw importError!;
    final result = pendingImport == null
        ? importResult
        : await pendingImport!.future;
    if (result != null) {
      sessions = [
        result,
        ...sessions.where((session) => session.id != result.id),
      ];
    }
    return result;
  }

  @override
  Future<MediaSession> process(String sessionId, CameraPatch patch) async {
    processes++;
    receivedPatch = patch;
    if (processError != null) throw processError!;
    final source = sessions.firstWhere((session) => session.id == sessionId);
    final result = pendingProcess == null
        ? fixture(
            id: sessionId,
            kind: source.inspection.kind,
            status: nextStatus,
            processingId: nextProcessingId,
            patch: patch,
          )
        : await pendingProcess!.future;
    sessions = [
      result,
      ...sessions.where((session) => session.id != sessionId),
    ];
    return result;
  }

  @override
  Future<bool> exportFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  ) async {
    exports++;
    exportedProcessingId = processingId;
    exportedAcknowledgment = acknowledgeIncomplete;
    if (correctedExportSessions != null) sessions = correctedExportSessions!;
    if (exportError != null) throw exportError!;
    return pendingExport == null ? true : await pendingExport!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedIds.add(sessionId);
    sessions = sessions.where((session) => session.id != sessionId).toList();
    if (deleteAfterCommitError != null) throw deleteAfterCommitError!;
  }

  @override
  Future<void> clearSessions() async {
    sessions = [];
    if (clearAfterCommitError != null) throw clearAfterCommitError!;
  }

  Map<String, Object?> editorState = {};
  List<MediaSession>? batchImportResult;
  Object? stateSaveError;
  Completer<void>? metadataLease;
  @override
  Future<Map<String, Object?>> loadEditorState() async => editorState;
  @override
  Future<void> saveEditorState(Map<String, Object?> state) async {
    if (stateSaveError != null) throw stateSaveError!;
    editorState = state;
  }

  @override
  Future<BatchImport> importBatch({required bool photos}) async {
    if (batchImportResult == null) {
      final one = await importMedia(photos: photos);
      return BatchImport(one == null ? [] : [one], [], one == null);
    }
    sessions = [
      ...batchImportResult!,
      ...sessions.where((s) => !batchImportResult!.any((b) => b.id == s.id)),
    ];
    return BatchImport(batchImportResult!, [], false);
  }

  @override
  Future<MediaSession> processMetadata(
    String sessionId,
    MetadataPatch patch,
  ) async {
    processes++;
    if (metadataLease != null) await metadataLease!.future;
    if (processError != null) {
      sessions = sessions
          .map((s) => s.id == sessionId ? s.withoutOutput() : s)
          .toList();
      throw processError!;
    }
    final source = sessions.firstWhere((s) => s.id == sessionId);
    final result = MediaSession(
      id: source.id,
      displayName: source.displayName,
      origin: source.origin,
      createdAt: source.createdAt,
      inspection: source.inspection,
      notes: [],
      processing: Processing(
        id: nextProcessingId,
        createdAt: DateTime.utc(2026),
        patch: const CameraPatch(make: '', model: ''),
        metadataPatch: patch,
        outputDisplayName: 'IMG_4827.${source.inspection.kind.name}',
        inspection: MediaInspection(
          kind: source.inspection.kind,
          byteCount: source.inspection.byteCount,
          metadata: patch.values.map((k, v) => MapEntry(k, v.toString())),
          structure: source.inspection.structure,
          notes: [],
        ),
        integrity: IntegrityReport(
          nextStatus,
          [const IntegrityCheck('Payload', 'passed', 'Matches')],
          nextStatus == IntegrityStatus.incomplete
              ? ['Opaque metadata not qualified.']
              : [],
        ),
      ),
    );
    sessions = [result, ...sessions.where((s) => s.id != sessionId)];
    return result;
  }

  @override
  Future<bool> exportBatch(List<Map<String, Object?>> items) async {
    exports++;
    return true;
  }

  @override
  Future<Map<String, Object?>?> importPreset() async => null;
  @override
  Future<bool> exportPreset(Map<String, Object?> preset) async => true;
  @override
  Future<Map<String, Object?>> verifyOriginal(
    String sessionId,
    String processingId,
  ) async => {'exactMatch': true};
  @override
  Future<void> openICloud() async {
    opens++;
  }
}
