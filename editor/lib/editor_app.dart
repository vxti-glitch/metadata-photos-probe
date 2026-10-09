import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'editor_controller.dart';
import 'media_bridge.dart';

import 'metadata_form.dart';

const _background = Color(0xFF0E1115);
const _surface = Color(0xFF191E25);
const _accent = Color(0xFF9CB5FF);
const _muted = Color(0xFF9BA6B4);

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
        onPrimary: Color(0xFF0F1B2E),
        onSurface: Color(0xFFE7EDF4),
        secondary: Color(0xFF7A9AE0),
        secondaryContainer: Color(0xFF243044),
        onSecondaryContainer: Color(0xFFDCE6F8),
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
        fillColor: _background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF323A45)),
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
      dividerColor: const Color(0xFF303743),
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
    return Scaffold(
      appBar: AppBar(
        leading: session == null
            ? null
            : IconButton(
                tooltip: 'Back to projects',
                onPressed: controller.busy
                    ? null
                    : () => controller.select(null),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
        title: const Row(
          children: [
            _MetadataMark(),
            SizedBox(width: 12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppBrand.header,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    Text(
                      AppBrand.headerSubtitle,
                      style: TextStyle(
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
            tooltip: 'About this build',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => _showAbout(context),
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
                      ] else if (session == null)
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

class _MetadataMark extends StatelessWidget {
  const _MetadataMark();
  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: CustomPaint(size: Size(34, 34), painter: _MetadataMarkPainter()),
  );
}

/// Neutral vector: four frame corners surrounding three metadata rows.
/// Geometry uses a 32-unit canvas so the app icon can share the same construction.
class _MetadataMarkPainter extends CustomPainter {
  const _MetadataMarkPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 32, 32),
        const Radius.circular(8),
      ),
      Paint()..color = _background,
    );
    final stroke = Paint()
      ..color = _accent
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final corners = Path()
      ..moveTo(10, 4)
      ..lineTo(4, 4)
      ..lineTo(4, 10)
      ..moveTo(22, 4)
      ..lineTo(28, 4)
      ..lineTo(28, 10)
      ..moveTo(4, 22)
      ..lineTo(4, 28)
      ..lineTo(10, 28)
      ..moveTo(22, 28)
      ..lineTo(28, 28)
      ..lineTo(28, 22);
    canvas.drawPath(corners, stroke);
    canvas.drawLine(const Offset(11, 10), const Offset(23, 10), stroke);
    canvas.drawLine(const Offset(11, 17), const Offset(20, 17), stroke);
    canvas.drawLine(const Offset(11, 24), const Offset(17, 24), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MetadataMarkPainter oldDelegate) => false;
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
      if (controller.batchSelection.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${controller.batchSelection.length} selected',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF9CB5FF),
                      ),
                    ),
                    TextButton(
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
                  onPressed: controller.busy
                      ? null
                      : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (context) => SafeArea(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: MetadataForm(
                                controller: controller,
                                session: controller.sessions.firstWhere(
                                  (s) => controller.batchSelection.contains(s.id),
                                ),
                                batch: true,
                              ),
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.edit_note_rounded, size: 20),
                  label: const Text('Edit selected files'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: controller.busy
                            ? null
                            : () => _exportBatch(context, controller),
                        icon: const Icon(Icons.folder_shared_outlined, size: 16),
                        label: const Text('Export selected copies'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: controller.busy
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
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    Text(
                      '${controller.queueCompletedCount}/${controller.queueTotal} ready',
                      style: const TextStyle(color: Color(0xFF9CB5FF), fontSize: 12),
                    ),
                  ],
                ),
                if (controller.queueFailedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${controller.queueFailedCount} failed or interrupted',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
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
                    backgroundColor: const Color(0xFF141C28),
                    color: const Color(0xFF9CB5FF),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (controller.queueCompletedCount > 0) ...[
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: controller.busy
                              ? null
                              : () => _exportBatch(context, controller, onlyReady: true),
                          child: const Text('Export ready'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: controller.busy
                              ? null
                              : () => _shareBatch(context, controller, onlyReady: true),
                          child: const Text('Share ready'),
                        ),
                      ),
                    ],
                    if (controller.queueFailedCount > 0) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: controller.busy ? null : controller.retryBatch,
                          child: const Text('Retry unfinished files'),
                        ),
                      ),
                    ],
                  ],
                ),
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
                              : item.status == 'failed' || item.status == 'interrupted'
                                  ? Icons.error_outline
                                  : Icons.hourglass_top_outlined,
                          size: 18,
                          color: item.status == 'completed'
                              ? const Color(0xFF9CB5FF)
                              : item.status == 'failed' || item.status == 'interrupted'
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
                        onPressed: controller.busy ? null : controller.retryBatch,
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

class _WorkflowNote extends StatelessWidget {
  const _WorkflowNote();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF141C28),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF233658)),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'THE PHOTOS WORKFLOW',
          style: TextStyle(
            color: _accent,
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
          style: TextStyle(color: _muted, fontSize: 11, height: 1.4),
        ),
      ],
    ),
  );
}

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
        color: error ? const Color(0xFF352025) : const Color(0xFF152238),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: error ? const Color(0xFF5A2530) : const Color(0xFF233658),
        ),
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
  final chosen = onlyReady && completedIds.isNotEmpty
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
                      (s) =>
                          s.processing?.integrity.limitations ?? <String>[],
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
  final chosen = onlyReady && completedIds.isNotEmpty
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
                      (s) =>
                          s.processing?.integrity.limitations ?? <String>[],
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

void _showAbout(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text(AppBrand.name),
    content: const SingleChildScrollView(
      child: Text(
        '0.4.0 · Build 5\n\nFlutter interface · Swift media engine\n\n'
        'Image camera changes have physical-device evidence on tested JPEG and HEIC samples. Video camera editing remains provisional. '
        'Files → Safari/iCloud → Photos is the selected workflow. Direct Photos saving without attribution is not established.\n\n'
        'Manual metadata editing, camera profiles, saved presets and batch processing run locally. Supported fields depend on the source format. '
        'Live Photo conversion and video editing are outside scope.\n\n'
        'Media and metadata stay local. Nothing is uploaded automatically.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);
