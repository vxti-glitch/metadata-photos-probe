import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_brand.dart';
import 'package:metadata_editor/media_bridge.dart';
import 'package:metadata_editor/media_models.dart';

import 'fake_media_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppBrand.bridgeChannel);
  final bridge = NativeMediaBridge(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'review reserves opaque source IDs and decodes exact native names',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return {sourceId: 'IMG_4827.HEIC'};
      });
      expect(await bridge.reserveOutputNames([sourceId]), {
        sourceId: 'IMG_4827.HEIC',
      });
      expect(received?.method, 'reserveOutputNames');
      expect(received?.arguments, {
        'sessionIds': [sourceId],
      });
    },
  );

  test(
    'review refuses missing, duplicate, unsafe and foreign native names',
    () async {
      for (final response in <Object?>[
        {},
        {outputId: 'IMG_4827.HEIC'},
        {sourceId: '../outside.HEIC'},
        {sourceId: 'IMG_4827.heic'},
        {sourceId: 4827},
        {sourceId: 'IMG_4827.HEIC', outputId: 'IMG_4827.HEIC'},
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => response);
        final ids = response is Map && response.length == 2
            ? [sourceId, outputId]
            : [sourceId];
        await expectLater(
          bridge.reserveOutputNames(ids),
          throwsFormatException,
        );
      }
      await expectLater(bridge.reserveOutputNames([]), throwsFormatException);
      await expectLater(
        bridge.reserveOutputNames([sourceId, sourceId]),
        throwsFormatException,
      );
    },
  );

  test(
    'support handoff uses a fixed native method without user data',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      await bridge.openSupportEmail();
      expect(received?.method, 'openSupportEmail');
      expect(received?.arguments, isNull);
      expect(AppBrand.supportEmail, 'vxti.dev@gmail.com');
      expect(AppBrand.supportSubject, 'Metadata Editor Support');
    },
  );

  test(
    'support handoff propagates the native email unavailable message',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'email_unavailable',
          message: 'Install or configure an email app, then try again.',
        );
      });
      await expectLater(
        bridge.openSupportEmail(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'email_unavailable',
          ),
        ),
      );
    },
  );

  test(
    'protocol version mismatch fails before accepting engine capabilities',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'protocolVersion': 999,
          'formats': ['jpeg'],
          'editableFields': ['make', 'model'],
          'videoStatus': 'provisional',
        },
      );
      await expectLater(bridge.capabilities(), throwsFormatException);
    },
  );
  test('exports opaque identifiers and acknowledgment rather than paths or file bytes', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return {'completed': true};
    });
    expect(await bridge.exportFiles(sourceId, outputId, true), isTrue);
    expect(received?.method, 'exportFiles');
    expect(received?.arguments, {
      'sessionId': sourceId,
      'processingId': outputId,
      'acknowledgeIncomplete': true,
    });
  });
  test(
    'native picker cancellation remains null rather than a fabricated session',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await bridge.importMedia(photos: true), isNull);
    },
  );
  test(
    'invalid identifier, format, camera value type and timestamp fail decoding',
    () {
      expect(
        () => MediaSession.decode({...sessionMap(), 'id': '../../outside'}),
        throwsFormatException,
      );
      expect(
        () => MediaSession.decode({...sessionMap(), 'createdAt': 'yesterday'}),
        throwsFormatException,
      );
      expect(
        () => MediaInspection.decode({...inspectionMap(), 'kind': 'raw'}),
        throwsFormatException,
      );
      expect(
        () => MediaInspection.decode({
          ...inspectionMap(),
          'metadata': {'make': 3},
        }),
        throwsFormatException,
      );
    },
  );
  test('malformed optional output labels fail as protocol format errors', () {
    final processing = <String, Object?>{
      'id': outputId,
      'createdAt': '2026-10-08T12:00:00Z',
      'patch': {'make': 'Test Make', 'model': 'Test Camera'},
      'outputInspection': inspectionMap(),
      'integrity': {
        'status': 'verified',
        'checks': [
          {'name': 'Payload', 'status': 'passed', 'detail': 'Matches.'},
        ],
        'limitations': <String>[],
      },
    };
    expect(
      () => Processing.decode({...processing, 'outputDisplayName': 4827}),
      throwsFormatException,
    );
    expect(
      () => Processing.decode({
        ...processing,
        'autoExportFolder': ['Files'],
      }),
      throwsFormatException,
    );
  });
  test(
    'unknown check status and empty check lists cannot certify integrity',
    () {
      expect(
        () => IntegrityReport.decode({
          'status': 'verified',
          'checks': [],
          'limitations': [],
        }),
        throwsFormatException,
      );
      expect(
        () => IntegrityReport.decode({
          'status': 'verified',
          'checks': [
            {
              'name': 'Media',
              'status': 'guessed',
              'detail': 'Not a real result',
            },
          ],
          'limitations': [],
        }),
        throwsFormatException,
      );
    },
  );
  test('duplicate native history identifiers are rejected', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => [sessionMap(), sessionMap()],
    );
    await expectLater(bridge.listSessions(), throwsFormatException);
  });
  test('missing native engine produces a clear recoverable message', () {
    expect(readableError(MissingPluginException()), contains('unavailable'));
    expect(
      readableError(
        PlatformException(
          code: 'permission',
          message: 'Photos permission is required.',
        ),
      ),
      'Photos permission is required.',
    );
  });

  test(
    'simplifyUserError translates technical errors into actionable guidance',
    () {
      expect(
        simplifyUserError(
          'Dates use YYYY:MM:DD HH:mm:ss for photos or ISO 8601 for videos.',
        ),
        contains('calendar icon'),
      );
      expect(
        simplifyUserError('latitude is out of range.'),
        contains('between -90 and 90'),
      );
      expect(
        simplifyUserError('A field cannot be changed and removed together.'),
        contains('Switch the dropdown to either "Set" or "Remove"'),
      );
      expect(
        simplifyUserError('Choose at least one metadata change.'),
        contains('Pick a camera profile'),
      );
      expect(
        simplifyUserError('iso is out of range.'),
        contains('between 1 and 65535'),
      );
      expect(
        simplifyUserError('EXIF ASCII field make cannot store non-ASCII text'),
        contains('only support standard ASCII characters'),
      );
      expect(
        simplifyUserError(
          'Video dates require ISO 8601 with an explicit time zone',
        ),
        contains('ISO 8601 with time zone'),
      );
      expect(
        simplifyUserError(
          'Native metadata processing or independent integrity verification failed.',
        ),
        contains('preserved'),
      );
      expect(
        simplifyUserError('Integrity checks are incomplete.'),
        contains('processed copy remains available'),
      );
      expect(
        simplifyUserError('altitude is out of range.'),
        contains('-100,000m and 100,000m'),
      );
      expect(
        simplifyUserError('Photos permission is required.'),
        contains('Full Library Access is optional'),
      );
    },
  );
}
