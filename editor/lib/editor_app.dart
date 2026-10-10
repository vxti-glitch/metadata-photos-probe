import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'editor_controller.dart';
import 'media_bridge.dart';

import 'metadata_form.dart';
import 'settings_screen.dart';

const _background = Color(0xFF000000);
const _surface = Color(0xFF1C1C1E);
const _accent = Color(0xFF0A84FF);
const _muted = Color(0xFF8E8E93);
const _border = Color(0xFF2C2C2E);

class MetadataEditorApp extends StatelessWidget {
  const MetadataEditorApp({super.key, this.controller});
  final EditorController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AppBrand.name,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      platform: TargetPlatform.iOS,
      scaffoldBackgroundColor: _background,
      colorScheme: const ColorScheme.dark(
        primary: _accent,
        surface: _surface,
        onPrimary: Color(0xFFFFFFFF),
        onSurface: Color(0xFFFFFFFF),
        secondary: Color(0xFF0A84FF),
        secondaryContainer: Color(0xFF2C2C2E),
        onSecondaryContainer: Color(0xFFFFFFFF),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _background,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        color: _surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      dividerColor: _border,
    ),
    home: EditorHome(controller: controller),
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
  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? EditorController(NativeMediaBridge());
    controller.addListener(_update);
    controller.initialize();
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

  @override
  Widget build(BuildContext context) {
    final session = controller.selected;
    final isBatch =
        controller.isBatchMode && controller.batchSelection.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: (session == null && !isBatch)
            ? null
            : IconButton(
                tooltip: 'Back to projects',
                onPressed: controller.busy
                    ? null
                    : isBatch
                    ? controller.exitBatchEditing
                    : () => controller.select(null),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
        title: Row(
          children: [
            const _MetadataMark(),
            const SizedBox(width: 12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isBatch
                          ? 'BATCH EDITING (${controller.batchSelection.length})'
                          : AppBrand.header,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      isBatch
                          ? 'Shared profile across selected files'
                          : AppBrand.headerSubtitle,
                      style: const TextStyle(
                        fontSize: 9,
                        color: _muted,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('openSettings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(controller: controller),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      if (controller.error != null)
                        _Message(
                          text: controller.error!,
                          error: true,
                          dismiss: controller.dismissMessage,
                        ),
                      if (controller.notice != null)
                        _Message(
                          text: controller.notice!,
                          dismiss: controller.dismissMessage,
                        ),
                      if (controller.busy) _Progress(controller: controller),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: ValueKey(
                      isBatch ? 'batch' : (session?.id ?? 'projects'),
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                    children: [
                      if (!controller.ready && !controller.busy) ...[
                        const _Panel(
                          child: Text(
                            'The media engine must be ready before editing. Your files have not been changed.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: controller.initialize,
                          child: const Text('Retry startup'),
                        ),
                      ] else if (isBatch)
                        MetadataForm(
                          key: const ValueKey('batch_editor'),
                          controller: controller,
                          session: controller.sessions.firstWhere(
                            (s) => controller.batchSelection.contains(s.id),
                            orElse: () => controller.sessions.first,
                          ),
                          batch: true,
                        )
                      else if (session == null)
                        _Projects(controller: controller)
                      else
                        MetadataForm(
                          key: ValueKey(session.id),
                          controller: controller,
                          session: session,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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

typedef _MetadataMark = MetadataMark;

/// Concept B Precision Viewfinder HUD:
/// Hairline reticle corners, precision crosshair ticks, and three telemetry tracks with an Apple System Blue focal dot.
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
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    // Hairline reticle corners
    final corners = Path()
      ..moveTo(8, 4)
      ..lineTo(4, 4)
      ..lineTo(4, 8)
      ..moveTo(24, 4)
      ..lineTo(28, 4)
      ..lineTo(28, 8)
      ..moveTo(4, 24)
      ..lineTo(4, 28)
      ..lineTo(8, 28)
      ..moveTo(24, 28)
      ..lineTo(28, 28)
      ..lineTo(28, 24);
    canvas.drawPath(corners, stroke);

    // Crosshairs
    final crossPaint = Paint()
      ..color = const Color(0xFF636366)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(16, 2), const Offset(16, 4.5), crossPaint);
    canvas.drawLine(const Offset(16, 27.5), const Offset(16, 30), crossPaint);
    canvas.drawLine(const Offset(2, 16), const Offset(4.5, 16), crossPaint);
    canvas.drawLine(const Offset(27.5, 16), const Offset(30, 16), crossPaint);

    // Telemetry lines
    final linePaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    // Line 1 with glowing blue focal dot
    final dotPaint = Paint()..color = const Color(0xFF0A84FF);
    canvas.drawCircle(const Offset(10, 11), 1.3, dotPaint);
    canvas.drawLine(const Offset(13, 11), const Offset(23, 11), linePaint);

    // Line 2
    final line2Paint = Paint()
      ..color = const Color(0xFFD1D1D6)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final dot2Paint = Paint()..color = const Color(0x660A84FF);
    canvas.drawCircle(const Offset(10, 16), 1.1, dot2Paint);
    canvas.drawLine(const Offset(13, 16), const Offset(20, 16), line2Paint);

    // Line 3
    final line3Paint = Paint()
      ..color = const Color(0xFF8E8E93)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final dot3Paint = Paint()..color = const Color(0x330A84FF);
    canvas.drawCircle(const Offset(10, 21), 0.9, dot3Paint);
    canvas.drawLine(const Offset(13, 21), const Offset(17, 21), line3Paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MetadataMarkPainter oldDelegate) => false;
}

class _Projects extends StatelessWidget {
  const _Projects({required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 14),
      const Text(
        AppBrand.headline,
        style: TextStyle(
          fontSize: 32,
          height: 1.12,
          letterSpacing: -1,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'Inspect camera information and create an edited copy on your iPhone. Your original stays untouched.',
        style: TextStyle(color: _muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 24),
      _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle('01', 'Choose a file'),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('importPhotos'),
              onPressed: controller.ready && !controller.busy
                  ? () => controller.importBatch(photos: true)
                  : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Import from Photos'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('importFiles'),
              onPressed: controller.ready && !controller.busy
                  ? () => controller.importBatch(photos: false)
                  : null,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Import from Files'),
            ),
            const SizedBox(height: 14),
            Text(
              controller.capabilities == null
                  ? 'JPEG · HEIC · MP4 · MOV'
                  : controller.capabilities!.formats
                        .map((format) => format.toUpperCase())
                        .join(' · '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      const _WorkflowNote(),
      const SizedBox(height: 28),
      Row(
        children: [
          const Expanded(
            child: Text(
              'LOCAL PROJECTS',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.5,
                color: _muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (controller.sessions.isNotEmpty)
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      final confirmed = await _confirm(
                        context,
                        'Clear local projects?',
                        'This removes only copies stored by this app. Photos, Files originals and exported copies stay unchanged.',
                      );
                      if (confirmed) await controller.clear();
                    },
              child: const Text('Clear all'),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (controller.sessions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${controller.batchSelection.length} of ${controller.sessions.length} selected',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: _accent,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: controller.busy
                          ? null
                          : () {
                              final allSelected = controller.sessions.every(
                                (s) => controller.batchSelection.contains(s.id),
                              );
                              for (final s in controller.sessions) {
                                controller.toggleBatch(s, !allSelected);
                              }
                            },
                      child: Text(
                        controller.sessions.every(
                              (s) => controller.batchSelection.contains(s.id),
                            )
                            ? 'Deselect all'
                            : 'Select all',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed:
                      controller.busy || controller.batchSelection.isEmpty
                      ? null
                      : controller.startBatchEditing,
                  icon: const Icon(Icons.edit_note_rounded, size: 20),
                  label: const Text('Edit selected files'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            controller.busy || controller.batchSelection.isEmpty
                            ? null
                            : () => _exportBatch(context, controller),
                        icon: const Icon(
                          Icons.folder_shared_outlined,
                          size: 16,
                        ),
                        label: const Text('Export selected copies'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            controller.busy || controller.batchSelection.isEmpty
                            ? null
                            : () => _shareBatch(context, controller),
                        icon: const Icon(Icons.ios_share_rounded, size: 16),
                        label: const Text('Share selected copies'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (controller.queue.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Batch Queue',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${controller.queueCompletedCount}/${controller.queueTotal} ready',
                      style: const TextStyle(color: _accent, fontSize: 12),
                    ),
                  ],
                ),
                if (controller.queueFailedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${controller.queueFailedCount} failed or interrupted',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: controller.queueTotal > 0
                        ? controller.queueCompletedCount / controller.queueTotal
                        : 0,
                    minHeight: 6,
                    backgroundColor: _border,
                    color: _accent,
                  ),
                ),
                const SizedBox(height: 12),
                if (controller.queueCompletedCount > 0) ...[
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: controller.busy
                              ? null
                              : () => _exportBatch(
                                  context,
                                  controller,
                                  onlyReady: true,
                                ),
                          child: const Text('Export ready'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: controller.busy
                              ? null
                              : () => _shareBatch(
                                  context,
                                  controller,
                                  onlyReady: true,
                                ),
                          child: const Text('Share ready'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (controller.queueFailedCount > 0) ...[
                  if (controller.queueCompletedCount > 0)
                    const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: controller.busy ? null : controller.retryBatch,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry unfinished files'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Batch: ${controller.queue.where((q) => q.status == "completed").length}/${controller.queue.length} ready',
                    style: const TextStyle(fontSize: 13),
                  ),
                  children: [
                    for (final item in controller.queue)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          item.status == 'completed'
                              ? Icons.check_circle_outline
                              : item.status == 'failed' ||
                                    item.status == 'interrupted'
                              ? Icons.error_outline
                              : Icons.hourglass_top_outlined,
                          size: 18,
                          color: item.status == 'completed'
                              ? _accent
                              : item.status == 'failed' ||
                                    item.status == 'interrupted'
                              ? Colors.redAccent
                              : Colors.white60,
                        ),
                        title: Text(
                          controller.sessions
                                  .where((s) => s.id == item.sessionId)
                                  .firstOrNull
                                  ?.displayName ??
                              'Local file',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${item.status}${item.message == null ? '' : ' · ${item.message}'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    if (controller.queue.any(
                      (q) => q.status == 'failed' || q.status == 'interrupted',
                    ))
                      TextButton(
                        onPressed: controller.busy
                            ? null
                            : controller.retryBatch,
                        child: const Text('Retry unfinished files'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (controller.sessions.isEmpty)
        const _Panel(
          child: Column(
            children: [
              Icon(Icons.layers_outlined, color: _muted, size: 28),
              SizedBox(height: 10),
              Text('No projects yet'),
              SizedBox(height: 5),
              Text(
                'Imported files and processed copies appear here.',
                style: TextStyle(color: _muted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      for (final session in controller.sessions)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _Panel(
            padding: const EdgeInsets.all(4),
            child: ListTile(
              enabled: !controller.busy,
              onTap: () => controller.select(session),
              leading: Checkbox(
                value: controller.batchSelection.contains(session.id),
                onChanged: controller.busy
                    ? null
                    : (value) =>
                          controller.toggleBatch(session, value ?? false),
              ),
              title: Text(
                session.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${session.inspection.kind.label} · ${session.inspection.sizeLabel} · ${session.processing == null ? "Original" : "Processed copy"}',
              ),
              trailing: IconButton(
                tooltip: 'Remove ${session.displayName}',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: controller.busy
                    ? null
                    : () async {
                        final confirmed = await _confirm(
                          context,
                          'Remove local project?',
                          'Only this app’s copies will be deleted. Your original and exported copies stay unchanged.',
                        );
                        if (confirmed) await controller.delete(session);
                      },
              ),
            ),
          ),
        ),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: padding, child: child),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.number, this.title);
  final String number;
  final String title;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        number,
        style: const TextStyle(
          color: _accent,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
    ],
  );
}

class WorkflowNote extends StatelessWidget {
  const WorkflowNote({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF132720),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF224436)),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'THE PHOTOS WORKFLOW',
          style: TextStyle(
            color: Color(0xFF84E4C7),
            fontSize: 10,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 8),
        Text(
          '1  Save the processed copy to Files.\n2  Upload that file at iCloud.com/Photos in Safari.\n3  Let it sync, then check it in Apple Photos.',
          style: TextStyle(fontSize: 13, height: 1.65),
        ),
        SizedBox(height: 8),
        Text(
          'Requires iCloud Photos, a browser upload and an internet connection. If the button opens another browser, open Safari manually for the tested upload workflow.',
          style: TextStyle(color: Color(0xFF90B0A0), fontSize: 11, height: 1.4),
        ),
      ],
    ),
  );
}

typedef _WorkflowNote = WorkflowNote;

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.dismiss,
    this.error = false,
  });
  final String text;
  final bool error;
  final VoidCallback dismiss;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(
        color: error ? const Color(0xFF2C1518) : _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: error ? const Color(0xFF5A2026) : _border),
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

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> _exportBatch(
  BuildContext context,
  EditorController controller, {
  bool onlyReady = false,
}) async {
  final completedIds = controller.queue
      .where((q) => q.status == 'completed')
      .map((q) => q.sessionId)
      .toSet();
  final chosen = onlyReady
      ? controller.sessions.where((s) => completedIds.contains(s.id)).toList()
      : controller.sessions
            .where((s) => controller.batchSelection.contains(s.id))
            .toList();
  final targets = onlyReady
      ? chosen
            .where(
              (s) =>
                  s.processing != null && !s.processing!.integrity.hasMismatch,
            )
            .toList()
      : chosen.toList();
  final needs = targets.any(
    (s) => s.processing?.integrity.needsAcknowledgment ?? false,
  );
  var acknowledgment = false;
  if (needs) {
    acknowledgment =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Export with limitations?'),
            content: SingleChildScrollView(
              child: Text(
                targets
                    .expand(
                      (s) => s.processing?.integrity.limitations ?? <String>[],
                    )
                    .toSet()
                    .join('\n'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Accept & export'),
              ),
            ],
          ),
        ) ??
        false;
    if (!acknowledgment) return;
  }
  await controller.exportSelectedBatch(
    acknowledgeIncomplete: acknowledgment,
    onlyReady: onlyReady,
  );
}

Future<void> _shareBatch(
  BuildContext context,
  EditorController controller, {
  bool onlyReady = false,
}) async {
  final completedIds = controller.queue
      .where((q) => q.status == 'completed')
      .map((q) => q.sessionId)
      .toSet();
  final chosen = onlyReady
      ? controller.sessions.where((s) => completedIds.contains(s.id)).toList()
      : controller.sessions
            .where((s) => controller.batchSelection.contains(s.id))
            .toList();
  final targets = onlyReady
      ? chosen
            .where(
              (s) =>
                  s.processing != null && !s.processing!.integrity.hasMismatch,
            )
            .toList()
      : chosen.toList();
  final needs = targets.any(
    (s) => s.processing?.integrity.needsAcknowledgment ?? false,
  );
  var acknowledgment = false;
  if (needs) {
    acknowledgment =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Share with limitations?'),
            content: SingleChildScrollView(
              child: Text(
                targets
                    .expand(
                      (s) => s.processing?.integrity.limitations ?? <String>[],
                    )
                    .toSet()
                    .join('\n'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Accept & share'),
              ),
            ],
          ),
        ) ??
        false;
    if (!acknowledgment) return;
  }
  await controller.shareSelectedBatch(
    acknowledgeIncomplete: acknowledgment,
    onlyReady: onlyReady,
  );
}
