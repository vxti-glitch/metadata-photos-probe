import 'package:flutter/services.dart';

import 'app_brand.dart';
import 'media_models.dart';
import 'metadata_patch.dart';

abstract interface class MediaBridge {
  Future<MediaCapabilities> capabilities();
  Future<List<MediaSession>> listSessions();
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
  });
}

class NativeMediaBridge implements MediaBridge {
  NativeMediaBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(AppBrand.bridgeChannel);
  final MethodChannel _channel;

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
  Future<bool> exportBatch(List<Map<String, Object?>> items) async =>
      objectMap(
        await _channel.invokeMethod<Object?>('exportFilesBatch', {
          'items': items,
        }),
      )['completed'] ==
      true;
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
    return result['completed'] == true;
  }

  @override
  Future<bool> shareBatch(List<Map<String, Object?>> items) async =>
      objectMap(
        await _channel.invokeMethod<Object?>('shareFilesBatch', {
          'items': items,
        }),
      )['completed'] ==
      true;
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
  Future<Map<String, double>?> openLocationPicker({
    double? latitude,
    double? longitude,
  }) async {
    final result = await _channel.invokeMethod<Object?>(
      'openLocationPicker',
      <String, Object?>{'latitude': latitude, 'longitude': longitude},
    );
    if (result is! Map) return null;
    final lat = result['latitude'];
    final lng = result['longitude'];
    if (lat is num && lng is num) {
      return {'latitude': lat.toDouble(), 'longitude': lng.toDouble()};
    }
    return null;
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
      default:
        return error.message ??
            'The media engine could not complete this operation.';
    }
  }
  if (error is FormatException) {
    return 'The media engine returned an invalid response. Restart the app before retrying.';
  }
  if (error is MissingPluginException) {
    return 'The native media engine is unavailable in this build.';
  }
  return 'This operation could not complete. Your original is unchanged. Please retry.';
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
