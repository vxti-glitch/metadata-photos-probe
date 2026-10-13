import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/media_bridge.dart';

void main() {
  test('retained differences display only closed safe labels', () {
    final message = readableError(
      PlatformException(
        code: 'integrity',
        message: 'Copy failed preservation checks.',
        details: {
          'failedChecks': [
            'retained_metadata',
            'retained_metadata_field_iso',
            'retained_metadata_numeric_key',
            'retained_metadata_unnamed_key',
            'retained_metadata_unrecognized_key',
            'retained_metadata_location_tuple',
          ],
        },
      ),
    );
    expect(safeIntegrityCheckLabels(message), [
      'Unchanged metadata',
      'Unchanged ISO',
      'Unmapped numbered metadata',
      'Unnamed metadata',
      'Unrecognized metadata field',
      'Unchanged location metadata',
    ]);
  });

  test('malicious raw keys and values never become retained labels', () {
    final message = readableError(
      PlatformException(
        code: 'integrity',
        message: 'Copy failed preservation checks.',
        details: {
          'failedChecks': [
            'retained_metadata_field_file:///private/clip.mov',
            'retained_metadata_field_latitude=12.123456',
            'retained_metadata_numeric_key:secret',
            'retained_metadata_field_iso',
          ],
        },
      ),
    );
    expect(safeIntegrityCheckLabels(message), ['Unchanged ISO']);
    expect(message, isNot(contains('clip.mov')));
    expect(message, isNot(contains('12.123456')));
    expect(message, isNot(contains('secret')));
  });
}
