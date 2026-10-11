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
  int _selectedTabIndex = 0;
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

    PreferredSizeWidget? appBar;
    if (_selectedTabIndex == 0) {
      appBar = AppBar(
        leading: (session == null && !isBatch)
            ? null
            : IconButton(
                tooltip: 'Back to projects',
                onPressed: controller.busy || !controller.ready
                    ? null
                    : isBatch
                    ? controller.exitBatchEditing
                    : () => controller.select(null),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
        title: Row(
          children: [
            const MetadataMark(size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isBatch
                    ? 'Batch edit (${controller.batchSelection.length})'
                    : AppBrand.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
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
            onPressed: () => setState(() => _selectedTabIndex = 1),
          ),
        ],
      );
    }

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
                                child: const Text(
                                  'Local history could not be saved. Your latest settings or diagnostics may not survive a restart.',
                                  style: TextStyle(
                                    color: Colors.amber,
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
                          key: const ValueKey('batch_editor'),
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
                          children: [_Projects(controller: controller)],
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

    return Scaffold(
      appBar: appBar,
      body: IndexedStack(
        index: _selectedTabIndex,
        children: [
          editorBody,
          SettingsScreen(
            controller: controller,
            isTab: true,
            onOpenEditor: () => setState(() => _selectedTabIndex = 0),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: const Key('mainNavigationBar'),
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedTabIndex = index),
        backgroundColor: const Color(0xFF121214),
        indicatorColor: _accent.withValues(alpha: 0.25),
        destinations: [
          const NavigationDestination(
            key: Key('tabEditor'),
            icon: Icon(Icons.tune_rounded),
            label: 'Editor',
          ),
          const NavigationDestination(
            key: Key('tabSettings'),
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
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
      const SizedBox(height: 4),
      const Text(
        'Edit your metadata',
        style: TextStyle(
          fontSize: 26,
          height: 1.12,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Choose photos or videos, review your changes, then create a copy. Your originals stay unchanged.',
        style: TextStyle(color: _muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 18),
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
      const ExpansionTile(
        key: Key('homePhotosWorkflow'),
        tilePadding: EdgeInsets.zero,
        title: Text('Using your copy in Apple Photos'),
        children: [_WorkflowNote()],
      ),
      const SizedBox(height: 18),
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
                        'Remove all app-owned private working copies and local project history? Photos and Files originals, published Processed Media copies, and copies exported elsewhere stay unchanged.',
                      );
                      if (confirmed && context.mounted) {
                        await controller.clear();
                      }
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
                _ActionPair(
                  first: OutlinedButton.icon(
                    onPressed:
                        controller.busy || controller.batchSelection.isEmpty
                        ? null
                        : () => _shareBatch(context, controller),
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: const Text('Share copies'),
                  ),
                  second: OutlinedButton.icon(
                    onPressed:
                        controller.busy || controller.batchSelection.isEmpty
                        ? null
                        : () => _exportBatch(context, controller),
                    icon: const Icon(Icons.folder_shared_outlined, size: 16),
                    label: const Text('Export copies'),
                  ),
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Text(
                    'Fully verified copies may save automatically to Files. Copies with incomplete checks need review and explicit export.',
                    style: TextStyle(fontSize: 11, color: _muted),
                    textAlign: TextAlign.center,
                  ),
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
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Batch Queue',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${controller.queueCompletedCount}/${controller.queueTotal} processed',
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
                  _ActionPair(
                    first: FilledButton.tonal(
                      onPressed: controller.busy
                          ? null
                          : () => _exportBatch(
                              context,
                              controller,
                              onlyReady: true,
                            ),
                      child: const Text('Export processed'),
                    ),
                    second: OutlinedButton(
                      onPressed: controller.busy
                          ? null
                          : () => _shareBatch(
                              context,
                              controller,
                              onlyReady: true,
                            ),
                      child: const Text('Share processed'),
                    ),
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
                    'Batch: ${controller.queue.where((q) => q.status == "completed").length}/${controller.queue.length} processed',
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
              enabled: controller.ready && !controller.busy,
              onTap: () => controller.select(session),
              leading: Checkbox(
                value: controller.batchSelection.contains(session.id),
                onChanged: controller.busy || !controller.ready
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
                onPressed: controller.busy || !controller.ready
                    ? null
                    : () async {
                        final confirmed = await _confirm(
                          context,
                          'Remove local project?',
                          'Remove this local project and its private working copies? Your original, published Processed Media copies, and copies exported elsewhere stay unchanged.',
                        );
                        if (confirmed && context.mounted) {
                          await controller.delete(session);
                        }
                      },
              ),
            ),
          ),
        ),
    ],
  );
}

class _ActionPair extends StatelessWidget {
  const _ActionPair({required this.first, required this.second});
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 440 ||
          MediaQuery.textScalerOf(context).scale(14) > 18) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 8), second],
        );
      }
      return Row(
        children: [
          Expanded(child: first),
          const SizedBox(width: 8),
          Expanded(child: second),
        ],
      );
    },
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
          'Requires iCloud Photos and an internet connection. Use Safari for upload, then check the result in Photos. Source labels and Photos display are controlled by Apple and are not guaranteed.',
          style: TextStyle(color: Color(0xFF90B0A0), fontSize: 11, height: 1.4),
        ),
      ],
    ),
  );
}

typedef _WorkflowNote = WorkflowNote;

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
    final simplified = simplifyUserError(rawError);
    final code = errorCode ?? 'ERR_PROCESSING';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        key: const Key('diagnosticErrorBanner'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF221114),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFFF453A).withValues(alpha: 0.6),
            width: 1.2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF453A).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFFFF453A).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      code,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFF453A),
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Attention Needed',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('dismissErrorBannerButton'),
                  tooltip: 'Dismiss message',
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18, color: _muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              simplified,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFFE5E5EA),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('viewSolutionButton'),
                    onPressed: onViewFix,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF453A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 36),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 16),
                    label: const Text(
                      'Error details',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
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
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
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
  if (chosen.isEmpty) return;

  final readyTargets = chosen
      .where(
        (s) => s.processing != null && !s.processing!.integrity.hasMismatch,
      )
      .toList();

  if (readyTargets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No processed copies ready. Tap "Edit selected files" to apply metadata first.',
        ),
      ),
    );
    return;
  }

  var exportOnlyReady = onlyReady;
  if (!onlyReady && readyTargets.length < chosen.length) {
    final exportReady = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export ready copies?'),
        content: Text(
          '${readyTargets.length} of ${chosen.length} selected files have processed copies ready.\n\n'
          'Export the ${readyTargets.length} ready copies now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Export ${readyTargets.length} copies'),
          ),
        ],
      ),
    );
    if (exportReady != true) return;
    exportOnlyReady = true;
  }

  if (!context.mounted) return;
  final targets = exportOnlyReady ? readyTargets : chosen;
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
    onlyReady: exportOnlyReady,
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
  if (chosen.isEmpty) return;

  final readyTargets = chosen
      .where(
        (s) => s.processing != null && !s.processing!.integrity.hasMismatch,
      )
      .toList();

  if (readyTargets.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No processed copies ready. Tap "Edit selected files" to apply metadata first.',
        ),
      ),
    );
    return;
  }

  var shareOnlyReady = onlyReady;
  if (!onlyReady && readyTargets.length < chosen.length) {
    final shareReady = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share ready copies?'),
        content: Text(
          '${readyTargets.length} of ${chosen.length} selected files have processed copies ready.\n\n'
          'Share the ${readyTargets.length} ready copies now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Share ${readyTargets.length} copies'),
          ),
        ],
      ),
    );
    if (shareReady != true) return;
    shareOnlyReady = true;
  }

  if (!context.mounted) return;
  final targets = shareOnlyReady ? readyTargets : chosen;
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
    onlyReady: shareOnlyReady,
  );
}
