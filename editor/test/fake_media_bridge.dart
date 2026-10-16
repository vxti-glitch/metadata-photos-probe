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
  String? outputDisplayName,
  CameraPatch patch = const CameraPatch(
    make: 'Test Make',
    model: 'Test Camera',
  ),
  bool failedCheck = false,
  Map<String, String> additionalMetadata = const {},
  Map<String, String> additionalStructure = const {},
}) {
  final metadata = {
    'make': 'Original Make',
    'model': 'Original Camera',
    'lens': 'Original Lens',
    ...additionalMetadata,
  };
  MediaInspection inspection(Map<String, String> camera) => MediaInspection(
    kind: kind,
    byteCount: 4096,
    metadata: camera,
    structure: {'width': '120', 'height': '160', ...additionalStructure},
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
            outputDisplayName: outputDisplayName ?? 'IMG_4827.${kind.name}',
            autoExportFolder: status == IntegrityStatus.verified && !failedCheck
                ? 'On My iPhone/Metadata Editor/Processed Media'
                : null,
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
                if (status == IntegrityStatus.warning)
                  const IntegrityCheck(
                    'retained embedded metadata',
                    'warning',
                    'Additional details changed.',
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
  final reservedOutputNames = <String, String>{};
  Completer<Map<String, String>>? pendingReservation;
  Object? reservationError;
  int reservations = 0;
  int _nextOutputDigits = 4827;
  @override
  Future<Map<String, String>> reserveOutputNames(
    List<String> sessionIds,
  ) async {
    reservations++;
    if (reservationError != null) throw reservationError!;
    if (pendingReservation != null) return pendingReservation!.future;
    return {
      for (final id in sessionIds)
        id: reservedOutputNames.putIfAbsent(id, () {
          final kind = sessions.firstWhere((s) => s.id == id).inspection.kind;
          final ext = kind == MediaKind.jpeg ? 'JPG' : kind.name.toUpperCase();
          final used = {
            ...reservedOutputNames.values.map((name) => name.toUpperCase()),
            ...sessions
                .map((s) => s.processing?.outputDisplayName?.toUpperCase())
                .whereType<String>(),
          };
          String name;
          do {
            name = 'IMG_${_nextOutputDigits++}.$ext';
          } while (used.contains(name));
          return name;
        }),
    };
  }

  List<MediaSession> sessions = [];
  MediaSession? importResult = fixture();
  Completer<MediaSession?>? pendingImport;
  Completer<MediaSession>? pendingProcess;
  Completer<bool>? pendingExport;
  Object? importError;
  Object? processError;
  Object? startupError;
  Map<String, List<String>> fieldsByFormat = const {};
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
      fieldsByFormat,
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
            outputDisplayName: reservedOutputNames[sessionId],
            patch: patch,
          )
        : await pendingProcess!.future;
    sessions = [
      result,
      ...sessions.where((session) => session.id != sessionId),
    ];
    reservedOutputNames.remove(sessionId);
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
    reservedOutputNames.remove(sessionId);
    deletedIds.add(sessionId);
    sessions = sessions.where((session) => session.id != sessionId).toList();
    if (deleteAfterCommitError != null) throw deleteAfterCommitError!;
  }

  int clears = 0;
  @override
  Future<void> clearSessions() async {
    reservedOutputNames.clear();
    clears++;
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
        outputDisplayName:
            reservedOutputNames[sessionId] ??
            'IMG_4827.${source.inspection.kind.name}',
        autoExportFolder: nextStatus == IntegrityStatus.verified
            ? 'On My iPhone/Metadata Editor/Processed Media'
            : null,
        inspection: MediaInspection(
          kind: source.inspection.kind,
          byteCount: source.inspection.byteCount,
          metadata: patch.values.map((k, v) => MapEntry(k, v.toString())),
          structure: source.inspection.structure,
          notes: [],
        ),
        integrity: IntegrityReport(
          nextStatus,
          [
            const IntegrityCheck('Payload', 'passed', 'Matches'),
            if (nextStatus == IntegrityStatus.warning)
              const IntegrityCheck(
                'retained embedded metadata',
                'warning',
                'Additional details changed.',
              ),
          ],
          nextStatus == IntegrityStatus.incomplete
              ? ['Opaque metadata not qualified.']
              : [],
        ),
      ),
    );
    sessions = [result, ...sessions.where((s) => s.id != sessionId)];
    reservedOutputNames.remove(sessionId);
    return result;
  }

  @override
  Future<bool> exportBatch(List<Map<String, Object?>> items) async {
    exports++;
    return true;
  }

  int shares = 0;
  String? sharedProcessingId;
  bool? sharedAcknowledgment;
  List<Map<String, Object?>>? sharedBatchItems;

  @override
  Future<bool> shareFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  ) async {
    shares++;
    sharedProcessingId = processingId;
    sharedAcknowledgment = acknowledgeIncomplete;
    return true;
  }

  @override
  Future<bool> shareBatch(List<Map<String, Object?>> items) async {
    shares++;
    sharedBatchItems = items;
    return true;
  }

  @override
  Future<Map<String, Object?>?> importPreset() async {
    presetImports++;
    return nextImportedPreset;
  }

  int presetImports = 0;
  Map<String, Object?>? nextImportedPreset;
  int presetExports = 0;
  Map<String, Object?>? exportedPreset;
  @override
  Future<bool> exportPreset(Map<String, Object?> preset) async {
    presetExports++;
    exportedPreset = preset;
    return true;
  }

  @override
  Future<Map<String, Object?>> verifyOriginal(
    String sessionId,
    String processingId,
  ) async => {'exactMatch': true};
  @override
  Future<void> openICloud() async {
    opens++;
  }

  final List<String> openedUrls = [];
  @override
  Future<void> openUrl(String url) async {
    openedUrls.add(url);
  }

  int supportEmailOpens = 0;
  Object? supportEmailFailure;
  Completer<void>? supportEmailCompletion;
  @override
  Future<void> openSupportEmail() async {
    supportEmailOpens++;
    if (supportEmailCompletion != null) await supportEmailCompletion!.future;
    if (supportEmailFailure != null) throw supportEmailFailure!;
  }

  Map<String, double>? nextLocationPickerResult;
  String? lastLocationPickerAppearance;
  @override
  Future<Map<String, double>?> openLocationPicker({
    double? latitude,
    double? longitude,
    String appearance = 'system',
  }) async {
    lastLocationPickerAppearance = appearance;
    return nextLocationPickerResult ??
        (latitude != null && longitude != null
            ? {'latitude': latitude, 'longitude': longitude}
            : null);
  }

  Map<String, String>? nextHostDevice;
  @override
  Future<Map<String, String>?> getHostDevice() async =>
      nextHostDevice ??
      {
        'brand': 'Apple',
        'profileId': 'apple-iphone-15-pro-max',
        'model': 'iPhone 15 Pro Max',
        'hardware': 'iPhone16,2',
      };
}
