import 'dart:async';

import 'package:metadata_editor/media_bridge.dart';
import 'package:metadata_editor/media_models.dart';

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
    return const MediaCapabilities(
      ['jpeg', 'heic', 'mp4', 'mov'],
      ['make', 'model', 'lens'],
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

  @override
  Future<void> openICloud() async {
    opens++;
  }
}
