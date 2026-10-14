import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/editor_controller.dart';
import 'package:metadata_editor/media_models.dart';
import 'package:metadata_editor/metadata_patch.dart';

import 'fake_media_bridge.dart';

void main() {
  Map<String, Object?> report(
    String status,
    String name,
    String checkStatus, {
    List<String> limitations = const [],
  }) => {
    'status': status,
    'checks': [
      {'name': 'Payload', 'status': 'passed', 'detail': 'Matched'},
      {'name': name, 'status': checkStatus, 'detail': 'Checked'},
    ],
    'limitations': limitations,
  };
  test('additional details warning does not block export', () {
    final value = IntegrityReport.decode(
      report('warning', 'retained embedded metadata', 'warning'),
    );
    expect(value.checks.last.consumerName, 'Other file details');
    expect(value.checks.last.name, 'retained embedded metadata');
    expect(value.hasAdditionalDetailsWarning, isTrue);
    expect(value.hasMismatch, isFalse);
    expect(value.needsAcknowledgment, isFalse);
  });
  test('incomplete warning needs acknowledgment and malformed warnings are rejected', () {
    final value = IntegrityReport.decode(
      report(
        'incomplete',
        'retained embedded metadata',
        'warning',
        limitations: ['Limited'],
      ),
    );
    expect(value.hasAdditionalDetailsWarning, isTrue);
    expect(value.needsAcknowledgment, isTrue);
    expect(
      () => IntegrityReport.decode(report('warning', 'Payload', 'warning')),
      throwsFormatException,
    );
    expect(
      () => IntegrityReport.decode(
        report('warning', 'retained embedded metadata', 'failed'),
      ),
      throwsFormatException,
    );
    expect(
      () => IntegrityReport.decode(
        report(
          'warning',
          'retained embedded metadata',
          'warning',
          limitations: ['Limited'],
        ),
      ),
      throwsFormatException,
    );
  });
  test('single warning exports without claiming full verification', () async {
    final bridge = FakeMediaBridge()
      ..sessions = [fixture()]
      ..nextStatus = IntegrityStatus.warning;
    final controller = EditorController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.select(controller.sessions.single);
    await controller.processMetadata(
      MetadataPatch(values: {'make': 'Apple', 'model': 'iPhone'}),
    );
    expect(controller.canExport, isTrue);
    expect(controller.selected!.processing!.autoExportFolder, isNull);
    expect(controller.notice, 'Processed copy ready.');
    expect(
      controller.selected!.processing!.integrity.hasAdditionalDetailsWarning,
      isTrue,
    );
    await controller.exportFiles();
    expect(bridge.exports, 1);
    expect(bridge.exportedAcknowledgment, isFalse);
  });
  test(
    'batch warning completes every copy and failed checks remain blocking',
    () async {
      final bridge = FakeMediaBridge()
        ..sessions = [fixture(), fixture(id: nextOutputId)]
        ..nextStatus = IntegrityStatus.warning;
      final controller = EditorController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      final patch = MetadataPatch(values: {'make': 'Apple', 'model': 'iPhone'});
      await controller.processBatch({sourceId: patch, nextOutputId: patch});
      expect(
        controller.queue.every((item) => item.status == 'completed'),
        isTrue,
      );
      expect(
        controller.sessions.every(
          (item) => item.processing!.integrity.hasAdditionalDetailsWarning,
        ),
        isTrue,
      );
      expect(
        IntegrityReport.decode(report('mismatch', 'Payload', 'failed'))
            .hasMismatch,
        isTrue,
      );
    },
  );
}
