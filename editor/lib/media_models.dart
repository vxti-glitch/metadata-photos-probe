import 'dart:convert';

import 'metadata_patch.dart';

enum MediaKind {
  jpeg,
  heic,
  png,
  mp4,
  mov;

  bool get isImage => this == jpeg || this == heic || this == png;
  String get label => name.toUpperCase();
}

enum IntegrityStatus { verified, incomplete, mismatch }

Map<String, Object?> objectMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected an object.');
  return value.map((key, value) {
    if (key is! String) throw const FormatException('Invalid object key.');
    return MapEntry(key, value);
  });
}

String requiredString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String) throw FormatException('Invalid $key.');
  return field;
}

List<String> strings(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Map<String, String> stringMap(Object? value) {
  final map = objectMap(value);
  return Map<String, String>.unmodifiable(
    map.map((key, value) {
      if (value is! String) {
        throw const FormatException('Invalid metadata value.');
      }
      return MapEntry(key, value);
    }),
  );
}

String identifier(Map<String, Object?> value, String key) {
  final result = requiredString(value, key);
  if (!RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')
      .hasMatch(result)) {
    throw FormatException('Invalid $key identifier.');
  }
  return result;
}

DateTime timestamp(Map<String, Object?> value, String key) {
  final result = DateTime.tryParse(requiredString(value, key));
  if (result == null) throw FormatException('Invalid $key timestamp.');
  return result;
}

class CameraPatch {
  const CameraPatch({required this.make, required this.model, this.lens});
  final String make;
  final String model;
  final String? lens;
  Map<String, Object?> toMap() => {'make': make, 'model': model, 'lens': lens};

  String? validate(MediaKind kind) {
    if (!kind.isImage && lens != null && lens!.isNotEmpty) {
      return 'Lens editing is available for images only.';
    }
    for (final value in [make, model, ?lens]) {
      if (value.trim().isEmpty ||
          utf8.encode(value).length > 256 ||
          value.runes.any(
            (rune) => rune < 32 || (rune >= 127 && rune <= 159),
          )) {
        return 'Use 1–256 UTF-8 bytes per field, without control characters.';
      }
      if (kind == MediaKind.heic && value.runes.any((rune) => rune > 127)) {
        return 'HEIC camera changes currently support ASCII text only.';
      }
    }
    return null;
  }
}

class MediaInspection {
  const MediaInspection({
    required this.kind,
    required this.byteCount,
    required this.metadata,
    required this.structure,
    required this.notes,
    this.location,
  });
  final MediaKind kind;
  final int byteCount;
  final Map<String, String> metadata;
  final Map<String, String> structure;
  final List<String> notes;
  final Map<String, Object?>? location;

  factory MediaInspection.decode(Object? data) {
    final value = objectMap(data);
    final kind = MediaKind.values.where((kind) => kind.name == value['kind']);
    final size = value['byteCount'];
    if (kind.length != 1 || size is! int || size < 0) {
      throw const FormatException('Invalid media inspection.');
    }
    return MediaInspection(
      kind: kind.single,
      byteCount: size,
      metadata: stringMap(value['metadata']),
      structure: stringMap(value['structure']),
      notes: strings(value['notes']),
      location: value['location'] == null
          ? null
          : Map<String, Object?>.unmodifiable(objectMap(value['location'])),
    );
  }

  String get sizeLabel {
    if (byteCount < 1024) return '$byteCount bytes';
    if (byteCount < 1024 * 1024) {
      return '${(byteCount / 1024).toStringAsFixed(1)} KB';
    }
    return '${(byteCount / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

class IntegrityCheck {
  const IntegrityCheck(this.name, this.status, this.detail);
  final String name;
  final String status;
  final String detail;
  factory IntegrityCheck.decode(Object? data) {
    final value = objectMap(data);
    final status = requiredString(value, 'status');
    if (!['passed', 'failed', 'notChecked'].contains(status)) {
      throw const FormatException('Invalid integrity check.');
    }
    return IntegrityCheck(
      requiredString(value, 'name'),
      status,
      requiredString(value, 'detail'),
    );
  }
}

class IntegrityReport {
  const IntegrityReport(this.status, this.checks, this.limitations);
  final IntegrityStatus status;
  final List<IntegrityCheck> checks;
  final List<String> limitations;
  bool get hasMismatch =>
      status == IntegrityStatus.mismatch ||
      checks.any((check) => check.status == 'failed');
  bool get needsAcknowledgment =>
      status == IntegrityStatus.incomplete ||
      limitations.isNotEmpty ||
      checks.any((check) => check.status == 'notChecked');
  factory IntegrityReport.decode(Object? data) {
    final value = objectMap(data);
    final status = IntegrityStatus.values.where(
      (status) => status.name == value['status'],
    );
    final checks = value['checks'];
    if (status.length != 1 || checks is! List || checks.isEmpty) {
      throw const FormatException('Invalid integrity report.');
    }
    return IntegrityReport(
      status.single,
      List<IntegrityCheck>.unmodifiable(checks.map(IntegrityCheck.decode)),
      strings(value['limitations']),
    );
  }
}

class Processing {
  const Processing({
    required this.id,
    required this.createdAt,
    required this.patch,
    required this.inspection,
    required this.integrity,
    this.metadataPatch,
    this.outputDisplayName,
    this.autoExportFolder,
  });
  final String id;
  final DateTime createdAt;
  final CameraPatch patch;
  final MetadataPatch? metadataPatch;
  final String? outputDisplayName;
  final String? autoExportFolder;
  final MediaInspection inspection;
  final IntegrityReport integrity;
  factory Processing.decode(Object? data) {
    final value = objectMap(data);
    final patch = objectMap(value['patch']);
    final isFull = patch.containsKey('values');
    final fullPatch = isFull ? MetadataPatch.decode(patch) : null;
    final lens = isFull ? fullPatch!.values['lensModel'] : patch['lens'];
    if (lens != null && lens is! String) {
      throw const FormatException('Invalid lens.');
    }
    final outputDisplayName = value['outputDisplayName'];
    final autoExportFolder = value['autoExportFolder'];
    if ((outputDisplayName != null && outputDisplayName is! String) ||
        (autoExportFolder != null && autoExportFolder is! String)) {
      throw const FormatException('Invalid output display information.');
    }
    return Processing(
      id: identifier(value, 'id'),
      createdAt: timestamp(value, 'createdAt'),
      patch: CameraPatch(
        make: isFull
            ? (fullPatch!.values['make']?.toString() ?? '')
            : requiredString(patch, 'make'),
        model: isFull
            ? (fullPatch!.values['model']?.toString() ?? '')
            : requiredString(patch, 'model'),
        lens: lens as String?,
      ),
      metadataPatch: fullPatch,
      outputDisplayName: outputDisplayName as String?,
      autoExportFolder: autoExportFolder as String?,
      inspection: MediaInspection.decode(value['outputInspection']),
      integrity: IntegrityReport.decode(value['integrity']),
    );
  }
}

class MediaSession {
  const MediaSession({
    required this.id,
    required this.displayName,
    required this.origin,
    required this.createdAt,
    required this.inspection,
    required this.notes,
    this.details = const {},
    this.previewPath,
    this.processing,
  });
  final String id;
  final String displayName;
  final String origin;
  final DateTime createdAt;
  final MediaInspection inspection;
  final List<String> notes;
  final Map<String, String> details;
  final String? previewPath;
  final Processing? processing;
  MediaSession withoutOutput() => MediaSession(
    id: id,
    displayName: displayName,
    origin: origin,
    createdAt: createdAt,
    inspection: inspection,
    notes: notes,
    details: details,
    previewPath: previewPath,
  );
  factory MediaSession.decode(Object? data) {
    final value = objectMap(data);
    final preview = value['previewPath'];
    if (preview != null && preview is! String) {
      throw const FormatException('Invalid preview.');
    }
    final result = MediaSession(
      id: identifier(value, 'id'),
      displayName: requiredString(value, 'displayName'),
      origin: requiredString(value, 'origin'),
      createdAt: timestamp(value, 'createdAt'),
      inspection: MediaInspection.decode(value['inspection']),
      notes: strings(value['notes']),
      details: value['details'] == null
          ? const {}
          : stringMap(value['details']),
      previewPath: preview as String?,
      processing: value['processing'] == null
          ? null
          : Processing.decode(value['processing']),
    );
    if (result.processing != null &&
        result.processing!.inspection.kind != result.inspection.kind) {
      throw const FormatException('The output format differs from the source.');
    }
    return result;
  }
}

class MediaCapabilities {
  const MediaCapabilities(
    this.formats,
    this.editableFields,
    this.videoStatus, [
    this.fieldsByFormat = const {},
  ]);
  final List<String> formats;
  final List<String> editableFields;
  final String videoStatus;
  final Map<String, List<String>> fieldsByFormat;
  Set<String> fieldsFor(MediaKind kind) =>
      (fieldsByFormat[kind.name] ?? editableFields).toSet();
  factory MediaCapabilities.decode(Object? data) {
    final value = objectMap(data);
    if (![1, 2].contains(value['protocolVersion'])) {
      throw const FormatException(
        'This app and its media engine are incompatible.',
      );
    }
    final formats = strings(value['formats']);
    final fields = strings(value['editableFields']);
    if (!formats.contains('jpeg') ||
        !fields.contains('make') ||
        !fields.contains('model')) {
      throw const FormatException(
        'Required editing capabilities are unavailable.',
      );
    }
    return MediaCapabilities(
      formats,
      fields,
      requiredString(value, 'videoStatus'),
      value['editableFieldsByFormat'] == null
          ? const {}
          : objectMap(value['editableFieldsByFormat'])
                .map((key, value) => MapEntry(key, strings(value))),
    );
  }
}
