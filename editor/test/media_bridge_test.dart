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
        simplifyUserError(
          'Native metadata processing or independent integrity verification failed.',
        ),
        contains('select a clean Camera Profile'),
      );
    },
  );
}
