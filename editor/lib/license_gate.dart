import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

class LicenseAccess {
  const LicenseAccess({
    required this.allowed,
    required this.reason,
    this.expiresAt,
    this.retryAfterSeconds,
  });

  final bool allowed;
  final String reason;
  final DateTime? expiresAt;
  final int? retryAfterSeconds;

  bool validAt(DateTime time) =>
      allowed && expiresAt != null && expiresAt!.isAfter(time);
}

abstract class LicenseBridge {
  Future<LicenseAccess> status();
  Future<LicenseAccess> refresh({String? key});
  Future<void> clear();
}

class NativeLicenseBridge implements LicenseBridge {
  const NativeLicenseBridge();

  static const _channel = MethodChannel(
    'com.vxtiglitch.metadataeditor/license_v1',
  );

  Future<LicenseAccess> _read(String method, [String? key]) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      method,
      key == null ? null : {'key': key},
    );
    final seconds = result?['expiresAt'];
    final retry = result?['retryAfterSeconds'];
    return LicenseAccess(
      allowed: result?['allowed'] == true,
      reason: result?['reason'] is String
          ? result!['reason'] as String
          : 'unavailable',
      expiresAt:
          seconds is num &&
              seconds.isFinite &&
              seconds > 0 &&
              seconds < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(
              (seconds * 1000).round(),
              isUtc: true,
            )
          : null,
      retryAfterSeconds:
          retry is num && retry.isFinite && retry > 0 && retry <= 86400
          ? retry.ceil()
          : null,
    );
  }

  @override
  Future<LicenseAccess> status() => _read('status');

  @override
  Future<LicenseAccess> refresh({String? key}) => _read('refresh', key);

  @override
  Future<void> clear() async {
    await _channel.invokeMethod<Object?>('clear');
  }
}

/// Place inside MaterialApp.builder around the navigator to cover every route.
class ZlarpLicenseGate extends StatefulWidget {
  const ZlarpLicenseGate({
    super.key,
    required this.child,
    this.bridge = const NativeLicenseBridge(),
  });

  final Widget child;
  final LicenseBridge bridge;

  static bool available(BuildContext context) =>
      context.findAncestorStateOfType<_ZlarpLicenseGateState>() != null;

  static Future<void> changeKey(BuildContext context) async {
    final gate = context.findAncestorStateOfType<_ZlarpLicenseGateState>();
    if (gate != null) await gate._changeKey();
  }

  @override
  State<ZlarpLicenseGate> createState() => _ZlarpLicenseGateState();
}

class _ZlarpLicenseGateState extends State<ZlarpLicenseGate>
    with WidgetsBindingObserver {
  static const _refreshInterval = Duration(hours: 6);
  final _key = TextEditingController();
  LicenseAccess? _access;
  DateTime? _lastRefresh;
  Future<void>? _operation;
  Timer? _timer;
  bool _busy = true;
  bool _covered = true;
  bool _suspended = false;
  bool _reveal = false;
  bool _hasOpened = false;
  int _epoch = 0;

  bool get _allowed =>
      !_covered && !_suspended && (_access?.validAt(DateTime.now()) ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check(forceRefresh: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _key.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _epoch++;
      _timer?.cancel();
      setState(() {
        _suspended = true;
        _covered = true;
      });
      return;
    }
    _suspended = false;
    unawaited(_resume());
  }

  Future<void> _resume() async {
    await _operation;
    if (!mounted || _suspended) return;
    await _check();
  }

  Future<void> _check({bool forceRefresh = false, String? key}) {
    if (_operation != null) return _operation!;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _covered = true;
    });
    final operation = () async {
      LicenseAccess result;
      try {
        final refresh =
            forceRefresh ||
            _lastRefresh == null ||
            !(_access?.validAt(DateTime.now()) ?? false) ||
            DateTime.now().difference(_lastRefresh!) >= _refreshInterval;
        result = refresh
            ? await widget.bridge.refresh(key: key)
            : await widget.bridge.status();
        if (refresh) {
          _lastRefresh = DateTime.now();
        } else if (!result.validAt(DateTime.now())) {
          // Native storage is authoritative. A cached grant can expire or be
          // rejected independently of the last value held by this widget.
          // Try the service once before presenting activation again.
          result = await widget.bridge.refresh();
          _lastRefresh = DateTime.now();
        }
      } catch (_) {
        result = const LicenseAccess(allowed: false, reason: 'unavailable');
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _access = result;
        _busy = false;
        _covered = false;
        if (result.validAt(DateTime.now())) {
          _hasOpened = true;
          _key.clear();
        }
      });
      _schedule();
    }();
    _operation = operation;
    return operation.whenComplete(() => _operation = null);
  }

  void _schedule() {
    _timer?.cancel();
    if (!_allowed) return;
    final expiry = _access!.expiresAt!;
    final refresh = _lastRefresh!.add(_refreshInterval);
    var next = expiry.isBefore(refresh) ? expiry : refresh;
    final retry = _access!.retryAfterSeconds;
    if (retry != null && retry > 0) {
      final retryAt = DateTime.now().add(Duration(seconds: retry));
      if (retryAt.isBefore(next)) next = retryAt;
    }
    final delay = next.difference(DateTime.now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (!mounted || _suspended) return;
      // Cover before beginning I/O, including when a cached grant expires.
      unawaited(_check(forceRefresh: true));
    });
  }

  Future<void> _changeKey() async {
    if (_busy) return;
    _timer?.cancel();
    setState(() {
      _covered = true;
      _busy = true;
    });
    try {
      await widget.bridge.clear();
    } catch (_) {
      // A clear failure must never reveal the protected app.
    }
    if (!mounted) return;
    setState(() {
      _access = const LicenseAccess(allowed: false, reason: 'missing_key');
      _lastRefresh = null;
      _covered = false;
      _busy = false;
    });
  }

  String get _message {
    switch (_access?.reason) {
      case 'invalid':
      case 'invalid_key':
      case 'revoked':
      case 'inactive':
      case 'not_entitled':
      case 'license_not_active':
        return 'This license is not active. Check your key or contact Zlarp.';
      case 'device_limit':
        return 'This license has reached its device limit. Manage your devices with Zlarp.';
      case 'expired':
        return 'Your license needs to be verified again.';
      case 'rate_limited':
        return 'Too many attempts. Wait a moment, then try again.';
      case 'unavailable':
      case 'offline':
      case 'network':
      case 'bad_token':
      case 'storage':
      case 'verification_failed':
      case 'temporarily_unavailable':
      case 'connection_required':
        return 'Unable to verify your license. Connect to the internet and retry.';
      case 'secure_storage_unavailable':
        return 'Your license could not be saved securely. Restart the app and retry.';
      default:
        return 'Enter the license key from your Zlarp purchase to open the app.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = _allowed;
    final colors = AppTheme.of(context);
    return Overlay.wrap(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_hasOpened)
            Offstage(
              offstage: !allowed,
              child: ExcludeFocus(
                excluding: !allowed,
                child: TickerMode(enabled: allowed, child: widget.child),
              ),
            ),
          if (!allowed)
            BlockSemantics(
              child: Scaffold(
                body: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(28),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AutofillGroup(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Icon(
                                Icons.lock_outline,
                                color: colors.accent,
                                size: 32,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Activate Metadata Editor',
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _busy ? 'Checking your license…' : _message,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.muted,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 28),
                              if (_busy)
                                const Center(child: CircularProgressIndicator())
                              else ...[
                                TextField(
                                  controller: _key,
                                  obscureText: !_reveal,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _check(
                                    forceRefresh: true,
                                    key: _key.text.trim().isEmpty
                                        ? null
                                        : _key.text.trim(),
                                  ),
                                  decoration: InputDecoration(
                                    labelText: 'License key',
                                    border: const OutlineInputBorder(),
                                    suffixIcon: IconButton(
                                      tooltip: _reveal
                                          ? 'Hide license key'
                                          : 'Show license key',
                                      onPressed: () =>
                                          setState(() => _reveal = !_reveal),
                                      icon: Icon(
                                        _reveal
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: () {
                                    FocusScope.of(context).unfocus();
                                    unawaited(
                                      _check(
                                        forceRefresh: true,
                                        key: _key.text.trim().isEmpty
                                            ? null
                                            : _key.text.trim(),
                                      ),
                                    );
                                  },
                                  child: const Text('Activate / retry'),
                                ),
                                TextButton(
                                  onPressed: _changeKey,
                                  child: const Text('Use a different key'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
