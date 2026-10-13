import 'package:flutter/services.dart';

import 'app_brand.dart';
import 'media_models.dart';
import 'metadata_patch.dart';

abstract interface class MediaBridge {
  Future<MediaCapabilities> capabilities();
  Future<List<MediaSession>> listSessions();
  Future<Map<String, String>> reserveOutputNames(List<String> sessionIds);
  Future<MediaSession?> importMedia({required bool photos});
  Future<MediaSession> process(String sessionId, CameraPatch patch);
  Future<bool> exportFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  );
  Future<void> cancel();
  Future<void> deleteSession(String sessionId);
  Future<void> clearSessions();
  Future<void> openICloud();
  Future<void> openUrl(String url);
  Future<void> openSupportEmail();
  Future<Map<String, Object?>> loadEditorState();
  Future<void> saveEditorState(Map<String, Object?> state);
  Future<BatchImport> importBatch({required bool photos});
  Future<MediaSession> processMetadata(String sessionId, MetadataPatch patch);
  Future<bool> exportBatch(List<Map<String, Object?>> items);
  Future<bool> shareFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  );
  Future<bool> shareBatch(List<Map<String, Object?>> items);
  Future<Map<String, Object?>?> importPreset();
  Future<bool> exportPreset(Map<String, Object?> preset);
  Future<Map<String, Object?>?> verifyOriginal(
    String sessionId,
    String processingId,
  );
  Future<Map<String, double>?> openLocationPicker({
    double? latitude,
    double? longitude,
    String appearance = 'system',
  });
  Future<Map<String, String>?> getHostDevice();
}

class NativeMediaBridge implements MediaBridge {
  NativeMediaBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(AppBrand.bridgeChannel);
  final MethodChannel _channel;

  @override
  Future<Map<String, String>> reserveOutputNames(
    List<String> sessionIds,
  ) async {
    if (sessionIds.isEmpty ||
        sessionIds.length > 50 ||
        sessionIds.toSet().length != sessionIds.length) {
      throw const FormatException('Invalid output name selection.');
    }
    final raw = objectMap(
      await _channel.invokeMethod<Object?>('reserveOutputNames', {
        'sessionIds': sessionIds,
      }),
    );
    if (raw.length != sessionIds.length || !sessionIds.every(raw.containsKey)) {
      throw const FormatException('Invalid output name reservation.');
    }
    final names = <String, String>{};
    for (final id in sessionIds) {
      final name = raw[id];
      if (name is! String ||
          !RegExp(r'^IMG_[0-9]{4}\.(JPG|JPEG|HEIC|HEIF|PNG|MP4|MOV)$')
              .hasMatch(name)) {
        throw const FormatException('Invalid output name reservation.');
      }
      names[id] = name;
    }
    if (names.values.toSet().length != names.length) {
      throw const FormatException('Invalid output name reservation.');
    }
    return names;
  }

  @override
  Future<MediaCapabilities> capabilities() async => MediaCapabilities.decode(
    await _channel.invokeMethod<Object?>('capabilities'),
  );
  @override
  Future<List<MediaSession>> listSessions() async {
    final result = await _channel.invokeMethod<Object?>('listSessions');
    if (result is! List) {
      throw const FormatException('Invalid session history.');
    }
    final sessions = result.map(MediaSession.decode).toList(growable: false);
    if (sessions.map((session) => session.id).toSet().length !=
        sessions.length) {
      throw const FormatException('Duplicate session identifiers.');
    }
    return sessions;
  }

  @override
  Future<MediaSession?> importMedia({required bool photos}) async {
    final result = await _channel.invokeMethod<Object?>(
      photos ? 'importPhotos' : 'importFiles',
    );
    return result == null ? null : MediaSession.decode(result);
  }

  @override
  Future<MediaSession> process(String sessionId, CameraPatch patch) async =>
      MediaSession.decode(
        await _channel.invokeMethod<Object?>('process', {
          'sessionId': sessionId,
          'patch': patch.toMap(),
        }),
      );
  @override
  Future<bool> exportFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  ) async {
    final result = objectMap(
      await _channel.invokeMethod<Object?>('exportFiles', {
        'sessionId': sessionId,
        'processingId': processingId,
        'acknowledgeIncomplete': acknowledgeIncomplete,
      }),
    );
    if (result['completed'] is! bool) {
      throw const FormatException('Invalid export response.');
    }
    return result['completed'] as bool;
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
  @override
  Future<void> deleteSession(String sessionId) =>
      _channel.invokeMethod<void>('deleteSession', {'sessionId': sessionId});
  @override
  Future<void> clearSessions() => _channel.invokeMethod<void>('clearSessions');
  @override
  Future<Map<String, Object?>?> verifyOriginal(
    String sessionId,
    String processingId,
  ) async {
    final result = await _channel.invokeMethod<Object?>('verifyOriginal', {
      'sessionId': sessionId,
      'processingId': processingId,
    });
    return result == null ? null : objectMap(result);
  }

  @override
  Future<Map<String, Object?>> loadEditorState() async =>
      objectMap(await _channel.invokeMethod<Object?>('loadEditorState'));
  @override
  Future<void> saveEditorState(Map<String, Object?> state) =>
      _channel.invokeMethod<void>('saveEditorState', {'state': state});
  @override
  Future<BatchImport> importBatch({required bool photos}) async =>
      BatchImport.decode(
        await _channel.invokeMethod<Object?>(
          photos ? 'importPhotosBatch' : 'importFilesBatch',
        ),
      );
  @override
  Future<MediaSession> processMetadata(
    String sessionId,
    MetadataPatch patch,
  ) async => MediaSession.decode(
    await _channel.invokeMethod<Object?>('processMetadata', {
      'sessionId': sessionId,
      'patch': patch.toMap(),
    }),
  );
  @override
  Future<bool> exportBatch(List<Map<String, Object?>> items) async {
    final result = objectMap(
      await _channel.invokeMethod<Object?>('exportFilesBatch', {
        'items': items,
      }),
    );
    if (result['completed'] is! bool) {
      throw const FormatException('Invalid export response.');
    }
    return result['completed'] as bool;
  }

  @override
  Future<bool> shareFiles(
    String sessionId,
    String processingId,
    bool acknowledgeIncomplete,
  ) async {
    final result = objectMap(
      await _channel.invokeMethod<Object?>('shareFiles', {
        'sessionId': sessionId,
        'processingId': processingId,
        'acknowledgeIncomplete': acknowledgeIncomplete,
      }),
    );
    if (result['completed'] is! bool) {
      throw const FormatException('Invalid share response.');
    }
    return result['completed'] as bool;
  }

  @override
  Future<bool> shareBatch(List<Map<String, Object?>> items) async {
    final result = objectMap(
      await _channel.invokeMethod<Object?>('shareFilesBatch', {'items': items}),
    );
    if (result['completed'] is! bool) {
      throw const FormatException('Invalid share response.');
    }
    return result['completed'] as bool;
  }

  @override
  Future<Map<String, Object?>?> importPreset() async {
    final value = await _channel.invokeMethod<Object?>('importPreset');
    return value == null ? null : objectMap(value);
  }

  @override
  Future<bool> exportPreset(Map<String, Object?> preset) async =>
      objectMap(
        await _channel.invokeMethod<Object?>('exportPreset', {
          'preset': preset,
        }),
      )['completed'] ==
      true;
  @override
  Future<void> openICloud() => _channel.invokeMethod<void>('openICloud');
  @override
  Future<void> openUrl(String url) =>
      _channel.invokeMethod<void>('openUrl', {'url': url});
  @override
  Future<void> openSupportEmail() =>
      _channel.invokeMethod<void>('openSupportEmail');
  @override
  Future<Map<String, double>?> openLocationPicker({
    double? latitude,
    double? longitude,
    String appearance = 'system',
  }) async {
    if (!const {'system', 'light', 'dark'}.contains(appearance)) {
      throw const FormatException('Invalid appearance preference.');
    }
    final result = await _channel.invokeMethod<Object?>(
      'openLocationPicker',
      <String, Object?>{
        'latitude': latitude,
        'longitude': longitude,
        'appearance': appearance,
      },
    );
    if (result is! Map) return null;
    final lat = result['latitude'];
    final lng = result['longitude'];
    if (lat is num && lng is num) {
      return {'latitude': lat.toDouble(), 'longitude': lng.toDouble()};
    }
    return null;
  }

  @override
  Future<Map<String, String>?> getHostDevice() async {
    try {
      final result = await _channel.invokeMethod<Object?>('getHostDevice');
      if (result is! Map) return null;
      return result.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return null;
    }
  }
}

String readableError(Object error) {
  if (error is PlatformException) {
    switch (error.code) {
      case 'canceled':
        return 'Operation canceled. Your original is unchanged.';
      case 'permission':
        return error.message ?? 'Allow access in Settings, then try again.';
      case 'busy':
        return 'Another operation is still finishing. Please wait.';
      case 'integrity':
        final message =
            error.message ??
            'The edited copy failed preservation checks. No output is available.';
        final checks = _integrityCheckSummary(error.details);
        return checks.isEmpty ? message : '$message Checks: $checks.';
      default:
        return error.message ??
            'The media engine could not complete this operation.';
    }
  }
  if (error is FormatException) {
    if (error.message.isNotEmpty &&
        !error.message.contains('Camera readback') &&
        !error.message.contains('Invalid processed session') &&
        !error.message.contains('Incompatible editor state') &&
        !error.message.startsWith('Unexpected character') &&
        !error.message.startsWith('Invalid JSON')) {
      return error.message;
    }
    return 'The media engine returned an invalid response. Restart the app before retrying.';
  }
  if (error is MissingPluginException) {
    return 'The native media engine is unavailable in this build.';
  }
  return 'This operation could not complete. Your original is unchanged. Please retry.';
}

String _integrityCheckSummary(Object? details) {
  if (details is! Map || details['failedChecks'] is! List) return '';
  final raw = details['failedChecks'] as List;
  if (raw.length > 32) return '';
  final known = _knownIntegrityCheckLabels();
  final selected = <String>{};
  for (final id in raw) {
    if (id is String && known.containsKey(id)) selected.add(known[id]!);
  }
  return selected.take(8).join(', ');
}

/// Restores only closed diagnostic labels, never an arbitrary error message.
/// Error history can contain old or externally supplied strings, so a malformed
/// summary is ignored rather than displayed in the reference guide.
List<String> safeIntegrityCheckLabels(String? message) {
  if (message == null || message.length > 4096 || !message.endsWith('.')) {
    return const [];
  }
  const marker = ' Checks: ';
  final start = message.lastIndexOf(marker);
  if (start < 0) return const [];
  final summary = message.substring(start + marker.length, message.length - 1);
  if (summary.isEmpty || summary.length > 1024) return const [];
  final labels = summary.split(', ');
  final known = _knownIntegrityCheckLabels().values.toSet();
  if (labels.length > 8 || labels.any((label) => !known.contains(label))) {
    return const [];
  }
  return List.unmodifiable(labels.toSet());
}

Map<String, String> _knownIntegrityCheckLabels() {
  const labels = {
    'container': 'File format',
    'requested_camera_metadata': 'Camera metadata',
    'requested_metadata': 'Requested metadata',
    'retained_metadata': 'Unchanged metadata',
    'retained_metadata_numeric_key': 'Unmapped numbered metadata',
    'retained_metadata_unnamed_key': 'Unnamed metadata',
    'retained_metadata_unrecognized_key': 'Unrecognized metadata field',
    'retained_metadata_location_tuple': 'Unchanged location metadata',
    'retained_location': 'Unchanged location',
    'complete_file_bytes': 'Complete file bytes',
    'image_presentation': 'Image appearance',
    'image_properties': 'Unchanged image properties',
    'jpeg_compressed_data': 'JPEG image data',
    'jpeg_retained_blocks': 'Unchanged JPEG blocks',
    'png_compressed_data': 'PNG image data',
    'heic_compressed_items': 'HEIC image data',
    'heic_item_graph': 'HEIC structure',
    'video_track_count': 'Video track count',
    'video_track_inventory': 'Video track inventory',
    'video_duration': 'Video duration',
    'video_compressed_samples': 'Encoded video samples',
    'report_status': 'Processing report status',
    'report_consistency': 'Processing report consistency',
  };
  final known = <String, String>{...labels};
  for (var index = 1; index <= 64; index++) {
    known['video_samples_track_$index'] = 'Track $index encoded media';
  }
  for (final field in metadataFields) {
    known['video_target_${field.key}'] = 'Video ${field.label}';
    known['image_target_${field.key}'] = 'Image ${field.label}';
    known['retained_metadata_field_${field.key}'] = 'Unchanged ${field.label}';
  }
  return known;
}

/// Simplifies raw engine or validation errors into plain-English, actionable
/// guidance that tells users what went wrong and how to fix it immediately.
String simplifyUserError(String message) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) {
    return 'An unexpected issue occurred. Please check your inputs and try again.';
  }

  // Location / coordinates
  if (trimmed.toLowerCase().contains('latitude') ||
      trimmed.toLowerCase().contains('longitude') ||
      trimmed.toLowerCase().contains('coordinate')) {
    return 'Location coordinates out of range. Latitude must be between -90 and 90, and Longitude between -180 and 180. Tip: tap the map pin to select a location visually.';
  }

  // Altitude
  if (trimmed.toLowerCase().contains('altitude')) {
    return 'Altitude value is out of range. Enter a value between -100,000m and 100,000m, or leave it blank.';
  }

  // Date format & explicit timezone
  if (trimmed.contains('Dates use') ||
      trimmed.contains('Invalid date') ||
      trimmed.contains('dateTimeOriginal') ||
      trimmed.contains('ISO 8601') ||
      trimmed.contains('explicit time zone')) {
    return 'Invalid date format. Use YYYY:MM:DD HH:mm:ss for photos or ISO 8601 with time zone (±HH:MM) for videos, or tap the calendar icon to set dates automatically.';
  }

  if (trimmed.toLowerCase().contains('read back')) {
    return 'The requested metadata could not be confirmed in the processed copy. No output is available. Keep the original and try a supported field or a different source file.';
  }

  // Time zone offset
  if (trimmed.contains('Time zones use') ||
      (trimmed.contains('offset') && trimmed.contains('14-hour'))) {
    return 'Invalid time zone offset. Enter ±HH:MM (e.g. -04:00 or +01:00).';
  }

  // ASCII / character set restrictions in EXIF
  if (trimmed.toLowerCase().contains('ascii') ||
      trimmed.toLowerCase().contains('non-ascii')) {
    return 'Camera tags (make, model, software) only support standard ASCII characters. Please remove emojis, symbols, or special characters.';
  }

  // Field conflict
  if (trimmed.contains('cannot be changed and removed together')) {
    return 'Conflicting field settings: a field cannot be set and removed at the same time. Switch the dropdown to either "Set" or "Remove".';
  }

  // Empty changes
  if (trimmed.contains('Choose at least one metadata change')) {
    return 'No changes selected. Pick a camera profile or edit at least one field before processing.';
  }

  // ISO / exposure numeric bounds
  if (trimmed.toLowerCase().contains('iso') &&
      (trimmed.contains('range') || trimmed.contains('number'))) {
    return 'Invalid ISO value. Enter a whole number between 1 and 65535, or leave it on Auto.';
  }

  // Direction / compass
  if (trimmed.toLowerCase().contains('direction')) {
    return 'Compass direction must be a number between 0 and 359.9 degrees.';
  }

  // Shutter / exposure time
  if (trimmed.toLowerCase().contains('exposure time') ||
      trimmed.toLowerCase().contains('shutter')) {
    return 'Invalid shutter speed. Enter standard fractions like 1/60, 1/125, or decimal seconds.';
  }

  // Aperture / fNumber
  if (trimmed.toLowerCase().contains('fnumber') ||
      trimmed.toLowerCase().contains('aperture')) {
    return 'Invalid aperture value. Enter a valid f-stop number like 1.8, 2.8, or 4.0.';
  }

  // Numeric fields
  if (trimmed.contains('must be a finite number') ||
      trimmed.contains('needs a whole number')) {
    return '$trimmed Make sure the field contains only numbers without symbols or units.';
  }

  // No ready copy
  if (trimmed.contains('unprocessed') ||
      trimmed.contains('ready') ||
      trimmed.contains('Select and process')) {
    return 'No processed copy ready. Tap "Process file" below to generate your clean copy first, then export or share.';
  }

  // Retained / competing metadata integrity conflict
  if (trimmed.toLowerCase().contains('incomplete') &&
      trimmed.toLowerCase().contains('integrity')) {
    return 'Some preservation checks are incomplete, but the processed copy remains available. Review the stated limitations and acknowledge them if you want to export it.';
  }

  if (trimmed.contains('integrity verification failed') ||
      trimmed.contains('retained embedded metadata') ||
      trimmed.contains('Integrity check failed') ||
      trimmed.contains('Integrity verification mismatch') ||
      trimmed.contains('integrity verification mismatch') ||
      trimmed.contains('unqualified media structure') ||
      trimmed.contains('integrity')) {
    return 'The editor could not confirm that the media and unrelated metadata were preserved. No output is available after a failed check. Keep the original, review Details, and retry only if the file and requested fields are supported.';
  }

  if (trimmed.toLowerCase().contains('processing failed') ||
      trimmed.toLowerCase().contains('could not finish creating')) {
    return 'The media engine could not finish this operation. The original is unchanged. Retry with the original file, or review the error code and Details report.';
  }

  // Storage / quota
  if (trimmed.contains('local media copy') ||
      trimmed.contains('storage') ||
      trimmed.contains('already exists')) {
    return 'Storage error: please ensure your device has sufficient free space, then retry.';
  }

  // Permissions
  if (trimmed.contains('Allow Photos access') ||
      trimmed.contains('Photos permission') ||
      trimmed.contains('permission')) {
    return 'Allow Metadata Editor to access the selected photos or videos in iOS Settings > Privacy & Security > Photos. Full Library Access is optional.';
  }

  // Busy
  if (trimmed.contains('finishing') || trimmed.contains('Wait for')) {
    return 'The media engine is finishing another operation. Please wait a moment.';
  }

  // Unsupported format
  if (trimmed.contains('unsupported') || trimmed.contains('malformed')) {
    return 'This file format or codec is not supported. Please use standard JPEG, PNG, HEIC, MP4, or QuickTime MOV files.';
  }

  return trimmed;
}

class BatchImport {
  const BatchImport(this.sessions, this.errors, this.canceled);
  final List<MediaSession> sessions;
  final List<String> errors;
  final bool canceled;
  factory BatchImport.decode(Object? raw) {
    final map = objectMap(raw);
    if (map['sessions'] is! List ||
        map['errors'] is! List ||
        map['canceled'] is! bool) {
      throw const FormatException('Invalid batch import.');
    }
    final sessions = (map['sessions'] as List)
        .map(MediaSession.decode)
        .toList();
    if (sessions.length > 50 ||
        sessions.map((s) => s.id).toSet().length != sessions.length) {
      throw const FormatException('Invalid batch selection.');
    }
    final errors = (map['errors'] as List).map((error) {
      final value = objectMap(error);
      return '${requiredString(value, 'name')}: ${requiredString(value, 'message')}';
    }).toList();
    return BatchImport(sessions, errors, map['canceled'] as bool);
  }
}
