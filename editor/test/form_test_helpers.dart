import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> expandManualEditing(WidgetTester tester) async {
  final tile = find.byKey(const Key('manualEditing'));
  if (tile.evaluate().isNotEmpty &&
      find.byKey(const Key('advancedMetadata')).evaluate().isEmpty) {
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: tile, matching: find.text('Manual editing')),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> openImportSource(WidgetTester tester, String key) async {
  if (find.byKey(Key(key)).evaluate().isEmpty) {
    final picker = find.byKey(const Key('selectMedia'));
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }
}
