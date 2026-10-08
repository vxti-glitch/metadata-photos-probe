import 'package:flutter/services.dart';

import 'media_models.dart';

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
}

class NativeMediaBridge implements MediaBridge {
  NativeMediaBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.zlarp.metadata/media_v1');
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
  Future<void> openICloud() => _channel.invokeMethod<void>('openICloud');
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
