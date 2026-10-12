import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'app_theme.dart';
import 'editor_controller.dart';
import 'media_bridge.dart';

import 'metadata_form.dart';
import 'settings_screen.dart';

class MetadataEditorApp extends StatefulWidget {
  const MetadataEditorApp({super.key, this.controller});
  final EditorController? controller;

  @override
  State<MetadataEditorApp> createState() => _MetadataEditorAppState();
}

class _MetadataEditorAppState extends State<MetadataEditorApp> {
  late final EditorController controller;

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? EditorController(NativeMediaBridge());
  }

  @override
  void dispose() {
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: AppBrand.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: switch (controller.appearance) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: EditorHome(controller: controller),
    ),
  );
}

class EditorHome extends StatefulWidget {
  const EditorHome({super.key, this.controller});
  final EditorController? controller;
  @override
  State<EditorHome> createState() => _EditorHomeState();
}

class _EditorHomeState extends State<EditorHome> {
  late final EditorController controller;
  int _selectedTabIndex = 0;
  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? EditorController(NativeMediaBridge());
    controller.addListener(_update);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.initialize();
    });
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_update);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  void _returnHome() {
    if (controller.busy || !controller.ready) return;
    for (final item in controller.sessions) {
      if (controller.batchSelection.contains(item.id)) {
        controller.toggleBatch(item, false);
      }
    }
    controller.select(null);
  }

  void _openErrorCodes() {
    setState(() => _selectedTabIndex = 1);
    openErrorGuidePage(
      context,
      controller: controller,
      onOpenEditor: () => setState(() => _selectedTabIndex = 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = controller.selected;
    final batchSources = controller.sessions
        .where((item) => controller.batchSelection.contains(item.id))
        .toList();
    final isBatch = controller.isBatchMode && batchSources.isNotEmpty;

    final isEditing = session != null || isBatch;
    final appBar = _selectedTabIndex == 0
        ? AppBar(
            leading: !isEditing
                ? null
                : IconButton(
                    key: const Key('backToHome'),
                    tooltip: 'Back to Home',
                    onPressed: controller.busy || !controller.ready
                        ? null
                        : _returnHome,
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                    ),
                  ),
            title: isEditing
                ? Text(
                    isBatch
                        ? '${batchSources.length} selected'
                        : 'Edit metadata',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            actions: [
              IconButton(
                key: const Key('openSettings'),
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => setState(() => _selectedTabIndex = 1),
              ),
              const SizedBox(width: 8),
            ],
          )
        : null;

    final editorBody = SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * 0.42,
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.error != null)
                            _DiagnosticErrorBanner(
                              rawError: controller.error!,
                              errorCode: controller.lastErrorCode,
                              onViewFix: _openErrorCodes,
                              onDismiss: controller.dismissMessage,
                            ),
                          if (controller.notice != null)
                            _Message(
                              text: controller.notice!,
                              dismiss: controller.dismissMessage,
                            ),
                          if (controller.statePersistenceError != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  'Local history could not be saved. Your latest settings or diagnostics may not survive a restart.',
                                  style: TextStyle(
                                    color: AppTheme.of(context).error,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          if (controller.busy)
                            _Progress(controller: controller),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: !controller.ready
                      ? ListView(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                          children: [
                            const _Panel(
                              child: Text(
                                'The media engine must be ready before editing. Your files have not been changed.',
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: controller.busy
                                  ? null
                                  : controller.initialize,
                              child: const Text('Retry startup'),
                            ),
                          ],
                        )
                      : isBatch
                      ? MetadataForm(
                          key: ValueKey(
                            'batch_editor-${controller.batchEditorRevision}-'
                            '${(controller.batchSelection.toList()..sort()).join(',')}',
                          ),
                          controller: controller,
                          session: batchSources.firstWhere(
                            (source) => source.id == session?.id,
                            orElse: () => batchSources.first,
                          ),
                          batch: true,
                          fillAvailableSpace: true,
                        )
                      : session == null
                      ? ListView(
                          key: const ValueKey('projects'),
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                          children: [_ImportHome(controller: controller)],
                        )
                      : MetadataForm(
                          key: ValueKey(session.id),
                          controller: controller,
                          session: session,
                          fillAvailableSpace: true,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return PopScope(
      canPop: _selectedTabIndex == 0 && !isEditing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectedTabIndex == 1) {
          setState(() => _selectedTabIndex = 0);
        } else if (!controller.busy && controller.ready) {
          _returnHome();
        }
      },
      child: Scaffold(
        appBar: appBar,
        body: IndexedStack(
          index: _selectedTabIndex,
          children: [
            editorBody,
            SettingsScreen(
              controller: controller,
              isTab: true,
              onBack: () => setState(() => _selectedTabIndex = 0),
              onOpenEditor: () => setState(() => _selectedTabIndex = 0),
            ),
          ],
        ),
      ),
    );
  }
}

class MetadataMark extends StatelessWidget {
  const MetadataMark({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size(size, size),
      painter: const MetadataMarkPainter(),
    ),
  );
}

/// Mirrors branding/mark.svg: a clear viewfinder and three metadata rows.
class MetadataMarkPainter extends CustomPainter {
  const MetadataMarkPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 32, 32),
        const Radius.circular(8),
      ),
      Paint()..color = const Color(0xFF1C1C1E),
    );
    final stroke = Paint()
      ..color = const Color(0xFFF5F5F7)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Stronger corners remain legible in compact app and Settings marks.
    final corners = Path()
      ..moveTo(10, 6)
      ..lineTo(6, 6)
      ..lineTo(6, 10)
      ..moveTo(22, 6)
      ..lineTo(26, 6)
      ..lineTo(26, 10)
      ..moveTo(6, 22)
      ..lineTo(6, 26)
      ..lineTo(10, 26)
      ..moveTo(22, 26)
      ..lineTo(26, 26)
      ..lineTo(26, 22);
    canvas.drawPath(corners, stroke);

    // Crosshairs
    final crossPaint = Paint()
      ..color = const Color(0xFF48484A)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(16, 3), const Offset(16, 4.5), crossPaint);
    canvas.drawLine(const Offset(16, 27.5), const Offset(16, 29), crossPaint);
    canvas.drawLine(const Offset(3, 16), const Offset(4.5, 16), crossPaint);
    canvas.drawLine(const Offset(27.5, 16), const Offset(29, 16), crossPaint);

    // Telemetry lines
    final linePaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round;

    // One strong blue dot anchors evenly spaced rows.
    final dotPaint = Paint()..color = const Color(0xFF0A84FF);
    canvas.drawCircle(const Offset(10, 10), 1.35, dotPaint);
    canvas.drawLine(const Offset(13, 10), const Offset(23, 10), linePaint);

    // Line 2
    final line2Paint = Paint()
      ..color = const Color(0xFFD1D1D6)
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round;
    final dot2Paint = Paint()..color = const Color(0xFF636366);
    canvas.drawCircle(const Offset(10, 16), 0.8, dot2Paint);
    canvas.drawLine(const Offset(13, 16), const Offset(20, 16), line2Paint);

    // Line 3
    final line3Paint = Paint()
      ..color = const Color(0xFF8E8E93)
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round;
    final dot3Paint = Paint()..color = const Color(0xFF48484A);
    canvas.drawCircle(const Offset(10, 22), 0.8, dot3Paint);
    canvas.drawLine(const Offset(13, 22), const Offset(17, 22), line3Paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MetadataMarkPainter oldDelegate) => false;
}

class _ImportHome extends StatelessWidget {
  const _ImportHome({required this.controller});
  final EditorController controller;

  Future<void> _chooseSource(BuildContext context) async {
    final photos = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('importPhotos'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photos'),
                subtitle: const Text('Choose one or more photos or videos'),
                onTap: () => Navigator.pop(context, true),
              ),
              ListTile(
                key: const Key('importFiles'),
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Files'),
                subtitle: const Text('Choose from your device or iCloud Drive'),
                onTap: () => Navigator.pop(context, false),
              ),
            ],
          ),
        ),
      ),
    );
    if (photos != null &&
        context.mounted &&
        controller.ready &&
        !controller.busy) {
      await controller.importBatch(photos: photos);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MetadataMark(size: 48),
        const SizedBox(height: 20),
        const Text(
          AppBrand.name,
          style: TextStyle(
            fontSize: 30,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'by ${AppBrand.developer}',
          style: TextStyle(color: colors.muted, fontSize: 14),
        ),
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: colors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('selectMedia'),
              onTap: controller.ready && !controller.busy
                  ? () => _chooseSource(context)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 52,
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 38,
                      color: colors.accent,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Select photos or videos',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Select multiple for a batch',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class WorkflowNote extends StatelessWidget {
  const WorkflowNote({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF132720) : const Color(0xFFEAF5EE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: dark ? const Color(0xFF224436) : const Color(0xFFBEDAC7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Using your copy in Apple Photos',
            style: TextStyle(
              color: dark ? const Color(0xFF84E4C7) : colors.success,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '1  Save the processed copy to Files.\n2  Upload that file at iCloud.com/Photos in Safari.\n3  Let it sync, then check it in Apple Photos.',
            style: TextStyle(fontSize: 13, height: 1.65),
          ),
          const SizedBox(height: 8),
          Text(
            'Requires iCloud Photos and an internet connection. Use Safari for upload, then check the result in Photos. Source labels and Photos display are controlled by Apple and are not guaranteed.',
            style: TextStyle(color: colors.muted, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticErrorBanner extends StatelessWidget {
  const _DiagnosticErrorBanner({
    required this.rawError,
    required this.errorCode,
    required this.onViewFix,
    required this.onDismiss,
  });

  final String rawError;
  final String? errorCode;
  final VoidCallback onViewFix;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const Key('diagnosticErrorBanner'),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.errorBorder.withValues(alpha: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 10),
              child: Icon(
                Icons.error_outline_rounded,
                color: colors.error,
                size: 20,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      errorCode == 'ERR_MEDIA_INTEGRITY'
                          ? 'This copy failed preservation checks.'
                          : simplifyUserError(rawError),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('viewSolutionButton'),
                    onPressed: onViewFix,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 40),
                      alignment: Alignment.centerLeft,
                      foregroundColor: colors.accent,
                    ),
                    child: const Text(
                      'Details',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('dismissErrorBannerButton'),
              tooltip: 'Dismiss error',
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded, size: 18, color: colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.dismiss});
  final String text;
  final VoidCallback dismiss;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: AppTheme.of(context).surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.of(context).border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss message',
            onPressed: dismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 14),
          Semantics(
            liveRegion: true,
            child: Text(
              controller.progressLabel,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if ([
            EditorOperation.importing,
            EditorOperation.processing,
            EditorOperation.exporting,
          ].contains(controller.operation))
            TextButton(
              key: const Key('cancel'),
              onPressed: controller.cancellationRequested
                  ? null
                  : controller.cancel,
              child: const Text('Cancel operation'),
            ),
        ],
      ),
    ),
  );
}
