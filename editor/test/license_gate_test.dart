import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/license_gate.dart';

class FakeLicenseBridge implements LicenseBridge {
  LicenseAccess access = const LicenseAccess(
    allowed: false,
    reason: 'missing_key',
  );
  Completer<LicenseAccess>? pending;
  LicenseAccess? statusAccess;
  bool throws = false;
  int refreshes = 0;
  int statuses = 0;
  int clears = 0;
  String? submittedKey;

  @override
  Future<LicenseAccess> refresh({String? key}) async {
    refreshes++;
    submittedKey = key;
    if (throws) throw StateError('network unavailable');
    return pending == null ? access : await pending!.future;
  }

  @override
  Future<LicenseAccess> status() async {
    statuses++;
    if (throws) throw StateError('status unavailable');
    return statusAccess ?? access;
  }

  @override
  Future<void> clear() async {
    clears++;
    access = const LicenseAccess(allowed: false, reason: 'missing_key');
  }
}

LicenseAccess active({Duration duration = const Duration(hours: 8)}) =>
    LicenseAccess(
      allowed: true,
      reason: 'active',
      expiresAt: DateTime.now().add(duration),
    );

Future<void> showGate(WidgetTester tester, LicenseBridge bridge) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          ZlarpLicenseGate(bridge: bridge, child: child!),
      home: const Scaffold(body: Text('Protected editor')),
    ),
  );
  await tester.pump();
}

class MountCounter extends StatefulWidget {
  const MountCounter({super.key, required this.onMount});
  final VoidCallback onMount;
  @override
  State<MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const Text('Protected editor');
}

void main() {
  testWidgets(
    'expired native resume status refreshes online before reopening',
    (tester) async {
      final bridge = FakeLicenseBridge()..access = active();
      await showGate(tester, bridge);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      bridge.statusAccess = const LicenseAccess(
        allowed: false,
        reason: 'expired',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bridge.statuses, 1);
      expect(bridge.refreshes, 2);
      expect(find.text('Protected editor'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('child mounts after activation and survives temporary lock', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge();
    var mounts = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            ZlarpLicenseGate(bridge: bridge, child: child!),
        home: MountCounter(onMount: () => mounts++),
      ),
    );
    await tester.pump();
    expect(mounts, 0);
    bridge.access = active();
    await tester.tap(find.text('Activate / retry'));
    await tester.pumpAndSettle();
    expect(mounts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Protected editor'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsOneWidget);
    expect(mounts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expiry timer covers editor while refreshing', (tester) async {
    final bridge = FakeLicenseBridge()
      ..access = active(duration: const Duration(seconds: 2));
    await showGate(tester, bridge);
    expect(find.text('Protected editor'), findsOneWidget);
    bridge.pending = Completer<LicenseAccess>();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Protected editor'), findsNothing);
    expect(bridge.refreshes, 2);
    bridge.pending!.complete(
      const LicenseAccess(allowed: false, reason: 'expired'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsNothing);
  });

  testWidgets('offline cached grant honors short native retry deadline', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge()
      ..access = LicenseAccess(
        allowed: true,
        reason: 'offline',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        retryAfterSeconds: 30,
      );
    await showGate(tester, bridge);
    bridge.pending = Completer<LicenseAccess>();
    await tester.pump(const Duration(seconds: 31));
    expect(bridge.refreshes, 2);
    expect(find.text('Protected editor'), findsNothing);
    bridge.pending!.complete(active());
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('launch waits for refresh and only exposes a future grant', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge()..pending = Completer<LicenseAccess>();
    await showGate(tester, bridge);
    expect(find.text('Protected editor'), findsNothing);
    expect(find.text('Checking your license…'), findsOneWidget);
    expect(bridge.refreshes, 1);
    bridge.pending!.complete(active());
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('invalid activation stays locked and submits the entered key', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge();
    await showGate(tester, bridge);
    await tester.enterText(find.byType(TextField), 'test-license');
    bridge.access = const LicenseAccess(allowed: false, reason: 'invalid_key');
    await tester.tap(find.text('Activate / retry'));
    await tester.pumpAndSettle();
    expect(bridge.submittedKey, 'test-license');
    expect(find.text('Protected editor'), findsNothing);
    expect(find.textContaining('not active'), findsOneWidget);
  });

  testWidgets('valid activation opens the editor; key reveal is accessible', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge();
    await showGate(tester, bridge);
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show license key'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
    await tester.enterText(find.byType(TextField), 'test-license');
    bridge.access = active();
    await tester.tap(find.text('Activate / retry'));
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('allowed without expiry or with expired grant is locked', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge()
      ..access = const LicenseAccess(allowed: true, reason: 'active');
    await showGate(tester, bridge);
    expect(find.text('Protected editor'), findsNothing);
    bridge.access = active(duration: const Duration(seconds: -1));
    await tester.tap(find.text('Activate / retry'));
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsNothing);
  });

  testWidgets('transport failure never bypasses activation', (tester) async {
    final bridge = FakeLicenseBridge()..throws = true;
    await showGate(tester, bridge);
    expect(find.text('Protected editor'), findsNothing);
    expect(find.textContaining('Unable to verify'), findsOneWidget);
  });

  testWidgets(
    'background hides editor; expired resume status cannot reopen it',
    (tester) async {
      final bridge = FakeLicenseBridge()..access = active();
      await showGate(tester, bridge);
      expect(find.text('Protected editor'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('Protected editor'), findsNothing);
      bridge.access = active(duration: const Duration(seconds: -1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Protected editor'), findsNothing);
      expect(bridge.statuses, 1);
      expect(bridge.refreshes, 2);
    },
  );

  testWidgets('concurrent activation taps coalesce into one refresh', (
    tester,
  ) async {
    final bridge = FakeLicenseBridge();
    await showGate(tester, bridge);
    bridge.pending = Completer<LicenseAccess>();
    await tester.tap(find.text('Activate / retry'));
    await tester.tap(find.text('Activate / retry'));
    expect(bridge.refreshes, 2);
    bridge.pending!.complete(active());
    await tester.pumpAndSettle();
    expect(find.text('Protected editor'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native bridge parses response and never bypasses missing plugin',
    (tester) async {
      const channel = MethodChannel('com.vxtiglitch.metadataeditor/license_v1');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'allowed': true,
          'reason': 'active',
          'expiresAt':
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch /
              1000,
        },
      );
      final result = await const NativeLicenseBridge().refresh(key: 'test');
      expect(result.validAt(DateTime.now()), isTrue);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException('License plugin unavailable');
      });
      await showGate(tester, const NativeLicenseBridge());
      await tester.pumpAndSettle();
      expect(find.text('Protected editor'), findsNothing);
      expect(find.textContaining('Unable to verify'), findsOneWidget);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
}
