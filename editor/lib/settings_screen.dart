import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'editor_app.dart';
import 'editor_controller.dart';
import 'legal_documents.dart';

const _background = Color(0xFF000000);
const _panel = Color(0xFF1C1C1E);
const _cardBorder = Color(0xFF2C2C2E);
const _accent = Color(0xFF0A84FF);
const _activeGreen = Color(0xFF34C759);
const _activeGreenBg = Color(0xFF132720);
const _activeGreenBorder = Color(0xFF2A5B44);
const _muted = Color(0xFF8E8E93);
const _subtle = Color(0xFF636366);
const _iconBg = Color(0xFF2C2C2E);

/// Grouped iOS Settings screen for Metadata Editor.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.isTab = false,
    this.onOpenEditor,
  });

  final EditorController controller;
  final bool isTab;
  final VoidCallback? onOpenEditor;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: AppBar(
      backgroundColor: _background,
      elevation: 0,
      leading: isTab
          ? null
          : IconButton(
              key: const Key('settingsBackButton'),
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
      title: const Text(
        'Settings',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
      centerTitle: true,
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                if (controller.statePersistenceError != null) ...[
                  _buildOperationFeedback(
                    'Local history could not be saved. Your latest settings or diagnostics may not survive a restart.',
                    isError: true,
                    key: const Key('settingsPersistenceWarning'),
                  ),
                  const SizedBox(height: 12),
                ],
                if (controller.error != null) ...[
                  _buildOperationFeedback(controller.error!, isError: true),
                  const SizedBox(height: 12),
                ] else if (controller.notice != null) ...[
                  _buildOperationFeedback(controller.notice!),
                  const SizedBox(height: 12),
                ],
                if (controller.busy) ...[
                  _buildOperationFeedback(
                    controller.progressLabel,
                    key: const Key('settingsOperationProgress'),
                  ),
                  const SizedBox(height: 12),
                ],
                _buildIdentityHero(context),
                const SizedBox(height: 20),
                _buildSectionHeader('STORAGE & PRESETS'),
                const SizedBox(height: 8),
                _buildDataStorageCard(context),
                const SizedBox(height: 20),
                _buildSectionHeader('HELP'),
                const SizedBox(height: 8),
                if (controller.lastErrorCode != null) ...[
                  _buildRecentErrorBanner(context),
                  const SizedBox(height: 8),
                ],
                _buildTroubleshootingCard(context),
                const SizedBox(height: 8),
                _buildDisclosure(
                  key: const Key('mediaExportDetails'),
                  title: 'Media & export',
                  subtitle: 'Formats, originals and Photos workflow',
                  icon: Icons.photo_library_outlined,
                  child: _buildMediaEngineCard(context),
                ),
                const SizedBox(height: 20),
                _buildSectionHeader('ABOUT'),
                const SizedBox(height: 8),
                _buildGeneralCard(context),
                const SizedBox(height: 8),
                _buildDisclosure(
                  key: const Key('engineDetails'),
                  title: 'Engine & diagnostics',
                  subtitle: controller.ready
                      ? 'Ready · processing stays on this device'
                      : 'Startup required before editing',
                  icon: Icons.info_outline_rounded,
                  child: _buildDiagnosticsCard(context),
                ),
                const SizedBox(height: 20),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildOperationFeedback(
    String message, {
    bool isError = false,
    Key? key,
  }) => Container(
    key:
        key ??
        Key(isError ? 'settingsOperationError' : 'settingsOperationNotice'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFF261215) : _panel,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: isError ? const Color(0xFF591C22) : _cardBorder,
      ),
    ),
    child: Text(
      message,
      style: TextStyle(
        color: isError ? const Color(0xFFFFD4CE) : Colors.white,
        height: 1.4,
      ),
    ),
  );

  Widget _buildIdentityHero(BuildContext context) => _buildCard(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const MetadataMark(size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    AppBrand.name,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 10,
                    runSpacing: 3,
                    children: [
                      Text(
                        'Version ${AppBrand.version}',
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                      Text(
                        'by ${AppBrand.developer}',
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _buildDisclosure({
    required Key key,
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
  }) => _buildCard(
    children: [
      Material(
        color: _panel,
        child: ExpansionTile(
          key: key,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(icon, color: _accent, size: 22),
          title: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
          children: [child],
        ),
      ),
    ],
  );

  Widget _buildSectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(left: 12, bottom: 2),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: _muted,
        letterSpacing: 1.2,
      ),
    ),
  );

  Widget _buildCard({required List<Widget> children}) => Container(
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _cardBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  Widget _buildGeneralCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('visitWebsiteRow'),
        icon: Icons.language_rounded,
        iconColor: _accent,
        title: 'Visit Website',
        trailing: const Icon(
          Icons.arrow_outward_rounded,
          size: 16,
          color: _muted,
        ),
        onTap: controller.busy || !controller.ready
            ? null
            : () => controller.openWebsite(),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('privacyPolicyRow'),
        icon: Icons.shield_outlined,
        iconColor: _accent,
        title: 'Privacy Policy',
        trailing: const Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: _muted,
        ),
        onTap: () => _openLegalSheet(
          context,
          title: 'Privacy Policy',
          content: LegalDocuments.privacyPolicy,
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('termsOfUseRow'),
        icon: Icons.description_outlined,
        iconColor: _accent,
        title: 'Terms of Use',
        trailing: const Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: _muted,
        ),
        onTap: () => _openLegalSheet(
          context,
          title: 'Terms of Use',
          content: LegalDocuments.termsOfUse,
        ),
      ),
    ],
  );

  Widget _buildRecentErrorBanner(BuildContext context) {
    final code = controller.lastErrorCode!;
    final item = kErrorGuideCatalog
        .where((entry) => entry.code == code)
        .firstOrNull;
    return Container(
      key: const Key('recentErrorBanner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF261215),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF591C22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFFF9B9B),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item?.title ?? 'Unexpected Processing Error',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      code,
                      key: const Key('recentErrorCodeBadge'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xFFFF9B9B),
                        fontSize: 11,
                      ),
                    ),
                    const Text(
                      'DIAGNOSTIC STEPS',
                      style: TextStyle(fontSize: 10, color: _muted),
                    ),
                  ],
                ),
                TextButton(
                  key: const Key('viewRecentErrorFixButton'),
                  onPressed: () =>
                      _openErrorGuidePage(context, highlightedCode: code),
                  child: const Text('View diagnostic steps'),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('dismissRecentErrorButton'),
            tooltip: 'Clear error history',
            onPressed: controller.clearLastError,
            icon: const Icon(Icons.close_rounded, size: 18, color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _buildTroubleshootingCard(BuildContext context) {
    final hasActiveError = controller.lastErrorCode != null;
    return _buildCard(
      children: [
        _buildRow(
          key: const Key('errorGuideRow'),
          icon: Icons.menu_book_rounded,
          iconColor: _accent,
          title: 'Error Codes & Fixes',
          subtitle: hasActiveError
              ? 'View steps for your latest issue'
              : 'Find an error and its next steps',
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: _muted,
          ),
          onTap: () => _openErrorGuidePage(
            context,
            highlightedCode: controller.lastErrorCode,
          ),
        ),
        const _IndentedDivider(),
        _buildRow(
          key: const Key('photosAttributionRow'),
          icon: Icons.lightbulb_outline_rounded,
          iconColor: _activeGreen,
          title: 'Photos Attribution Guide',
          subtitle: 'Embedded metadata and Photos labels are separate',
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: _muted,
          ),
          onTap: () => _showExplanationDialog(
            context,
            title: 'Photos Attribution Guide',
            body:
                'Embedded metadata and Photos app-origin labels are separate. Editing camera fields does not prove that a Photos attribution label is absent.\n\n'
                'Create an edited copy, then use Export to Files. You can manually upload that file through Safari to iCloud Photos and allow it to sync. Apple controls the resulting Photos presentation.\n\n'
                'This app does not write processed copies directly to Photos, alter Photos databases, or promise that Files, AirDrop, or iCloud imports suppress labels. Check the actual Photos information panel on your device.',
          ),
        ),
      ],
    );
  }

  Widget _buildMediaEngineCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('photosWorkflowRow'),
        icon: Icons.photo_library_outlined,
        iconColor: _activeGreen,
        title: 'The Photos Workflow',
        subtitle: 'Manual Files & Safari export workflow',
        trailing: _buildPill(
          text: 'MANUAL',
          bgColor: _activeGreenBg,
          borderColor: _activeGreenBorder,
          textColor: _activeGreen,
        ),
        onTap: () => _showExplanationDialog(
          context,
          title: 'The Photos Workflow',
          body:
              'Edits create a separate local copy while the imported original stays unchanged.\n\n'
              'Review the requested changes, then create the edited copy. Fully verified copies may appear in the app’s Files folder; use Export to Files to choose a destination. If verification is incomplete, review the limitations and explicitly acknowledge them before export. Failed checks block export.\n\n'
              'If you want the copy in iCloud Photos, upload it yourself through Safari and allow Photos to sync. The resulting Photos labels and presentation need a physical-device check.',
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('preserveOriginalsRow'),
        icon: Icons.lock_outline_rounded,
        iconColor: _accent,
        title: 'Preserve Source Originals',
        subtitle: 'Source files are never modified in-place',
        trailing: _buildPill(
          text: 'LOCKED ON',
          bgColor: _iconBg,
          borderColor: _cardBorder,
          textColor: _accent,
        ),
        onTap: () => _showExplanationDialog(
          context,
          title: 'Source File Immutability',
          body:
              'Metadata Editor guarantees that your original photos and videos are never altered or overwritten.\n\n'
              'All metadata edits, EXIF writes, GPS modifications, and date adjustments create fresh output files in sandboxed storage, leaving your source media bit-for-bit identical.',
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('supportedContainersRow'),
        icon: Icons.category_outlined,
        iconColor: _accent,
        title: 'Supported Media Containers',
        subtitle: controller.ready
            ? '${controller.capabilities!.formats.map((format) => format.toUpperCase()).join(' · ')} · Field and file-layout limits apply'
            : 'Format support is available after startup',
        trailing: const Icon(
          Icons.check_circle_outline_rounded,
          size: 18,
          color: _activeGreen,
        ),
      ),
    ],
  );

  Widget _buildDataStorageCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('clearCacheRow'),
        icon: Icons.delete_outline_rounded,
        iconColor: const Color(0xFFFF9B9B),
        title: 'Local Projects & Copies',
        subtitle: 'Private working copies; published files stay unchanged',
        trailing: OutlinedButton(
          key: const Key('clearCacheButton'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF9B9B),
            side: const BorderSide(color: Color(0x55FF9B9B)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: controller.busy || !controller.ready
              ? null
              : () => _confirmClearCache(context),
          child: const Text(
            'Clear',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        onTap: controller.busy || !controller.ready
            ? null
            : () => _confirmClearCache(context),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('resetPresetsRow'),
        icon: Icons.tune_rounded,
        iconColor: _accent,
        title: 'Saved Camera Presets',
        subtitle:
            '${controller.presets.length} custom preset(s) stored locally',
        trailing: OutlinedButton(
          key: const Key('resetPresetsButton'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: const BorderSide(color: _cardBorder),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: controller.busy || !controller.ready
              ? null
              : () => _confirmResetPresets(context),
          child: const Text(
            'Reset',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        onTap: controller.busy || !controller.ready
            ? null
            : () => _confirmResetPresets(context),
      ),
    ],
  );

  Widget _buildDiagnosticsCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('photosAccessHealthRow'),
        icon: Icons.photo_library_outlined,
        iconColor: _accent,
        title: 'Photos Access',
        subtitle:
            'Requested when importing from Photos; limited access is supported',
        trailing: _buildPill(
          text: 'ON IMPORT',
          bgColor: const Color(0x1F0A84FF),
          borderColor: const Color(0x660A84FF),
          textColor: _accent,
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('engineDiagnosticsRow'),
        icon: Icons.memory_rounded,
        iconColor: controller.ready ? _activeGreen : _muted,
        title: 'Swift Media Engine',
        subtitle:
            '${AppBrand.engineCore} · ${controller.ready ? 'Ready' : 'Not ready'} · Sandboxed local engine',
        trailing: Icon(
          controller.ready ? Icons.check_rounded : Icons.hourglass_empty,
          size: 18,
          color: controller.ready ? _activeGreen : _muted,
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('storageSandboxHealthRow'),
        icon: Icons.folder_special_outlined,
        iconColor: _activeGreen,
        title: 'Storage Sandbox',
        subtitle: 'Temporary working copies isolated in local sandbox',
        trailing: _buildPill(
          text: 'FILE-BACKED',
          bgColor: _activeGreenBg,
          borderColor: _activeGreenBorder,
          textColor: _activeGreen,
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('privacyGuaranteeRow'),
        icon: Icons.verified_user_outlined,
        iconColor: _activeGreen,
        title: 'Privacy Guarantee',
        subtitle: 'On-device processing · No analytics · Cloud-backed imports may download',
        trailing: const Icon(
          Icons.check_rounded,
          size: 18,
          color: _activeGreen,
        ),
      ),
    ],
  );

  Widget _buildFooter() => Center(
    child: Text(
      '${AppBrand.name} ${AppBrand.version} (Build ${AppBrand.buildNumber}) · © 2026 ${AppBrand.developer}',
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: _subtle,
        letterSpacing: 0.2,
      ),
    ),
  );

  Widget _buildRow({
    Key? key,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackTrailing =
              constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(15) > 21;
          final details = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null && !stackTrailing) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          );
          if (trailing == null || !stackTrailing) return details;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              details,
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 46),
                child: trailing,
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _buildPill({
    required String text,
    required Color bgColor,
    required Color borderColor,
    required Color textColor,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: borderColor),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        color: textColor,
      ),
    ),
  );

  void _showExplanationDialog(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _cardBorder),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        scrollable: true,
        content: Text(
          body,
          style: const TextStyle(color: _muted, fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  void _confirmClearCache(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _cardBorder),
          ),
          scrollable: true,
          title: const Text(
            'Clear Local Projects?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: const Text(
            'Remove your local project history, imported working files, and private edited/export staging copies? Published Processed Media files and copies exported elsewhere stay unchanged.\n\n'
            'Original files in Photos and Files are completely untouched.',
            style: TextStyle(color: _muted, fontSize: 14, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: _muted)),
            ),
            FilledButton(
              key: const Key('confirmClearCacheButton'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF8B2626),
                foregroundColor: Colors.white,
              ),
              onPressed: controller.busy || !controller.ready
                  ? null
                  : () async {
                      if (controller.busy || !controller.ready) return;
                      Navigator.of(context).pop();
                      await controller.clearCache();
                    },
              child: const Text('Clear Projects'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmResetPresets(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: _cardBorder),
          ),
          scrollable: true,
          title: const Text(
            'Reset Saved Presets?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: const Text(
            'Remove all custom saved camera recipes and presets?\n\n'
            'This also clears the remembered profile selection. Default researched camera profiles remain available.',
            style: TextStyle(color: _muted, fontSize: 14, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel', style: TextStyle(color: _muted)),
            ),
            FilledButton(
              key: const Key('confirmResetPresetsButton'),
              style: FilledButton.styleFrom(
                backgroundColor: _cardBorder,
                foregroundColor: _accent,
              ),
              onPressed: controller.busy || !controller.ready
                  ? null
                  : () async {
                      if (controller.busy || !controller.ready) return;
                      Navigator.of(context).pop();
                      await controller.resetPresets();
                    },
              child: const Text('Reset Presets'),
            ),
          ],
        ),
      ),
    );
  }

  void _openLegalSheet(
    BuildContext context, {
    required String title,
    required String content,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LegalDocumentSheet(title: title, content: content),
    );
  }

  void _openErrorGuidePage(BuildContext context, {String? highlightedCode}) {
    openErrorGuidePage(
      context,
      highlightedCode: highlightedCode,
      controller: controller,
      onOpenEditor: onOpenEditor,
    );
  }
}

void openErrorGuidePage(
  BuildContext context, {
  String? highlightedCode,
  required EditorController controller,
  VoidCallback? onOpenEditor,
}) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ErrorGuidePage(
        controller: controller,
        highlightedCode: highlightedCode,
        onOpenEditor: onOpenEditor,
      ),
    ),
  );
}

/// A Settings subpage; the editor remains mounted beneath the route.
class ErrorGuidePage extends StatelessWidget {
  const ErrorGuidePage({
    super.key,
    required this.controller,
    this.highlightedCode,
    this.onOpenEditor,
  });

  final EditorController controller;
  final String? highlightedCode;
  final VoidCallback? onOpenEditor;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        key: const Key('errorGuideBackButton'),
        tooltip: 'Back to Settings',
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: const Text('Error Codes & Fixes', style: TextStyle(fontSize: 18)),
    ),
    body: ErrorGuideSheet(
      controller: controller,
      highlightedCode: highlightedCode,
      isModal: false,
      onOpenEditor: onOpenEditor == null
          ? null
          : () {
              Navigator.of(context).pop();
              onOpenEditor!();
            },
    ),
  );
}

void openErrorGuideSheet(
  BuildContext context, {
  String? highlightedCode,
  EditorController? controller,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => ErrorGuideSheet(
      highlightedCode: highlightedCode,
      isModal: true,
      controller: controller,
    ),
  );
}

class ErrorGuideItem {
  const ErrorGuideItem({
    required this.code,
    required this.title,
    required this.category,
    required this.cause,
    required this.steps,
    required this.proTip,
  });

  final String code;
  final String title;
  final String category;
  final String cause;
  final List<String> steps;
  final String proTip;
}

const List<ErrorGuideItem> kErrorGuideCatalog = [
  ErrorGuideItem(
    code: 'ERR_DATE_FMT',
    title: 'Invalid Date or Timestamp Format',
    category: 'Dates',
    cause: 'Timestamps must strictly adhere to EXIF or ISO 8601 formatting. Freeform text, missing leading zeros, or colloquial separators are rejected by native parsers.',
    steps: [
      'For photos (JPEG/PNG/HEIC): Format as "YYYY:MM:DD HH:MM:SS" (e.g. 2026:10:10 14:30:00).',
      'For videos (MP4/MOV): Format as ISO 8601 with timezone offset (e.g. 2026-10-10T14:30:00-04:00).',
      'Choose Keep original, Set, or Randomize in the date controls. Review the resulting changes before creating the edited copy.',
    ],
    proTip: 'Use 24-hour time notation (00–23) and always include two-digit month, day, hour, minute, and second numbers.',
  ),
  ErrorGuideItem(
    code: 'ERR_GPS_BOUNDS',
    title: 'Coordinates Out of Range',
    category: 'Location',
    cause: 'Geographic coordinates must fall within standard physical boundaries: Latitude between -90.0 and +90.0, and Longitude between -180.0 and +180.0.',
    steps: [
      'Enter coordinates in pure decimal degrees (e.g. 37.7749 and -122.4194).',
      'Omit degree symbols (°), minutes (\'), seconds ("), and cardinal direction letters (N, S, E, W).',
      'Use a negative sign (-) to represent South latitudes or West longitudes.',
    ],
    proTip: 'Use Pick location when available, then review the latitude and longitude before creating the copy.',
  ),
  ErrorGuideItem(
    code: 'ERR_MEDIA_INTEGRITY',
    title: 'Media or Metadata Integrity Check Failed',
    category: 'Integrity',
    cause: 'The editor could not verify that the requested metadata change preserved the media and unrelated metadata. No processed output is available when a required check fails. This can be caused by an unsupported container layout, a readback mismatch, or a failed preservation check.',
    steps: [
      'Keep the original file and retry with only fields supported for its format.',
      'If the error repeats, use a separate clean copy of the file to check whether its container structure is supported.',
      'Use the error code and optional Details report when sharing a diagnostic; do not send private media or location data.',
    ],
    proTip: 'A successful metadata readback alone does not prove media integrity. Incomplete verification remains disclosed and requires your acknowledgment before export.',
  ),
  ErrorGuideItem(
    code: 'ERR_PROCESSING',
    title: 'Processing Could Not Complete',
    category: 'Processing',
    cause: 'The native media engine could not complete the requested operation or the current session/output token is no longer available. A failed operation does not change the imported original.',
    steps: [
      'Retry startup if the message asks you to refresh local history.',
      'Re-import the original and try one supported metadata change.',
      'If the error repeats, share the error code and safe diagnostic stage without sharing private media or location data.',
    ],
    proTip: 'Cancellation can finish after native file work settles. The app reconciles its local history before enabling export again.',
  ),
  ErrorGuideItem(
    code: 'ERR_FIELD_CONFLICT',
    title: 'Conflicting Set & Remove Directives',
    category: 'System',
    cause: 'A metadata field cannot be simultaneously targeted for writing a new value and deletion. This occurs when both "Set" and "Remove" are instructed.',
    steps: [
      'Locate the highlighted property in the metadata form.',
      'Change the action dropdown to either "Set" (to write a value) or "Remove" (to strip the tag).',
      'Choose "Keep" if you want to leave original camera data untouched.',
    ],
    proTip: 'Applying a researched camera profile automatically harmonizes field actions into a single consistent patch.',
  ),
  ErrorGuideItem(
    code: 'ERR_EXPORT_UNREADY',
    title: 'No Processed Copy Ready to Export',
    category: 'Storage',
    cause: 'There is no usable edited copy for the selected file, or incomplete verification still needs acknowledgment.',
    steps: [
      'Select the imported file and review your metadata changes.',
      'Choose Create edited copy and wait for processing to finish.',
      'Review any verification limitations. Export to Files becomes available only for an eligible copy.',
    ],
    proTip: 'Batch export also requires an eligible processed copy for each selected file. A failed integrity check blocks that copy.',
  ),
  ErrorGuideItem(
    code: 'ERR_PHOTOS_ACCESS',
    title: 'Photos Access Is Unavailable',
    category: 'System',
    cause: 'Photos authorization or access to the selected item is unavailable. Limited access may exclude that item, and cloud-backed originals may need a download.',
    steps: [
      'Open the iOS Settings app on your device.',
      'Scroll down to "Metadata Editor" (or navigate to Privacy & Security > Photos).',
      'Allow access to the selected items, or choose Full Library Access if you want to browse the whole library.',
      'Return to Metadata Editor and re-import your media.',
    ],
    proTip: 'Limited Photos access works for items you have authorized. Importing from Files does not require Photos access.',
  ),
  ErrorGuideItem(
    code: 'ERR_STORAGE_FULL',
    title: 'Local Storage or File Access Unavailable',
    category: 'Storage',
    cause: 'The app could not read or save an app-owned file. Low disk space, unavailable file access, or a damaged local session record can cause this code; it does not always mean the disk is full.',
    steps: [
      'Review Settings > Local Projects & Copies before removing private working copies. Published Processed Media files and copies exported elsewhere remain unchanged.',
      'Open iOS Settings > General > iPhone Storage and free enough space for the original plus working and output copies.',
      'Keep the provider original. If the file is cloud-backed, make sure it has downloaded before importing again. Review the safe diagnostic stage if the error persists.',
    ],
    proTip: 'Clearing local projects removes private working and export staging files. Provider originals, published Files copies, and copies exported elsewhere remain unchanged.',
  ),
  ErrorGuideItem(
    code: 'ERR_UNSUPPORTED_MEDIA',
    title: 'Unsupported Container or Codec',
    category: 'System',
    cause: 'The file format, internal layout, or requested metadata operation is unsupported. A recognized extension alone does not establish support.',
    steps: [
      'Ensure media uses standard formats: JPEG, PNG, HEIC, MP4, or QuickTime MOV.',
      'Check the field support shown for the imported file; video fields differ from photo fields.',
      'Retry with a supported field on a separate copy. Keep the original; the app does not convert or re-encode media to bypass this error.',
    ],
    proTip: 'Share the error code and safe diagnostic stage if this repeats. Do not send private media, file names, or location data.',
  ),
];

class ErrorGuideSheet extends StatefulWidget {
  const ErrorGuideSheet({
    super.key,
    this.highlightedCode,
    this.isModal = true,
    this.controller,
    this.onOpenEditor,
  });

  final String? highlightedCode;
  final bool isModal;
  final EditorController? controller;
  final VoidCallback? onOpenEditor;

  @override
  State<ErrorGuideSheet> createState() => _ErrorGuideSheetState();
}

class _ErrorGuideSheetState extends State<ErrorGuideSheet> {
  static final _categories = [
    'All',
    ...kErrorGuideCatalog.map((item) => item.category).toSet(),
  ];

  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _latestDetailsKey = GlobalKey();
  final Set<String> _expandedCodes = {};
  String _selectedCategory = 'All';
  String? _lastHighlight;
  bool _latestExpanded = false;
  late bool _catalogOpen;

  String? get _activeHighlight => widget.controller != null
      ? widget.controller!.lastErrorCode
      : widget.highlightedCode;

  bool get _hasFilters =>
      _searchController.text.trim().isNotEmpty || _selectedCategory != 'All';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _lastHighlight = _activeHighlight;
    _catalogOpen = _lastHighlight == null;
    widget.controller?.addListener(_handleControllerChange);
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_handleControllerChange);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ErrorGuideSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleControllerChange);
      widget.controller?.addListener(_handleControllerChange);
    }
    _updateHighlight();
  }

  void _updateHighlight() {
    final active = _activeHighlight;
    if (active == _lastHighlight) return;
    _lastHighlight = active;
    _latestExpanded = false;
    _catalogOpen = active == null;
    _expandedCodes.clear();
    _selectedCategory = 'All';
    _searchController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _handleControllerChange() {
    if (mounted) setState(_updateHighlight);
  }

  List<ErrorGuideItem> get _filteredItems {
    final query = _searchController.text.trim().toLowerCase();
    return kErrorGuideCatalog.where((item) {
      if (_selectedCategory != 'All' && item.category != _selectedCategory) {
        return false;
      }
      if (query.isEmpty) return true;
      return [
        item.code,
        item.title,
        item.category,
        item.cause,
        item.proTip,
        ...item.steps,
      ].any((text) => text.toLowerCase().contains(query));
    }).toList();
  }

  void _resetFilters() {
    setState(() {
      _searchController.clear();
      _selectedCategory = 'All';
    });
  }

  void _showLatestSteps() {
    setState(() => _latestExpanded = !_latestExpanded);
    if (!_latestExpanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final detailsContext = _latestDetailsKey.currentContext;
      if (mounted && detailsContext != null) {
        Scrollable.ensureVisible(
          detailsContext,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  Widget _latestIssue() {
    final code = _activeHighlight;
    final controller = widget.controller;
    final item = kErrorGuideCatalog
        .where((entry) => entry.code == code)
        .firstOrNull;
    final needsStartup = controller != null && !controller.ready;
    final hasIssue = code != null || needsStartup;
    return Container(
      key: const Key('latestIssueCard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasIssue ? const Color(0xFF51403A) : _cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                hasIssue
                    ? Icons.info_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 22,
                color: hasIssue ? const Color(0xFFE5B495) : _muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      code == null ? 'No recent errors' : 'Latest issue',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      code == null
                          ? needsStartup
                                ? 'Startup required'
                                : 'Nothing to troubleshoot yet'
                          : item?.title ?? 'An operation could not finish',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            code == null && !needsStartup
                ? 'If an operation fails, its code and next steps will appear here.'
                : needsStartup
                ? 'The editor needs to refresh local history before you can continue.'
                : 'Your original is unchanged. Review the steps, then return to your edits.',
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Colors.white70,
            ),
          ),
          if (code != null) ...[
            const SizedBox(height: 8),
            Text(
              'Code: $code',
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: _muted,
              ),
            ),
          ],
          if (hasIssue) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (needsStartup)
                  FilledButton.icon(
                    key: const Key('retryStartupFromGuide'),
                    onPressed: controller.busy ? null : controller.initialize,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry startup'),
                  ),
                if (item != null)
                  Semantics(
                    expanded: _latestExpanded,
                    child: OutlinedButton.icon(
                      key: const Key('viewLatestSteps'),
                      onPressed: _showLatestSteps,
                      icon: Icon(
                        _latestExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                      ),
                      label: Text(
                        _latestExpanded ? 'Hide steps' : 'View steps',
                      ),
                    ),
                  ),
                if (widget.onOpenEditor != null)
                  TextButton(
                    key: const Key('returnToEditorFromGuide'),
                    onPressed: widget.onOpenEditor,
                    child: const Text('Return to editor'),
                  ),
              ],
            ),
          ],
          if (item == null && code != null) ...[
            const SizedBox(height: 8),
            const Text(
              'This code has no catalog entry. Keep the original and share the code with the developer; avoid sharing private media or location data.',
              style: TextStyle(fontSize: 12, color: _muted, height: 1.4),
            ),
          ],
          if (_latestExpanded && item != null) ...[
            const SizedBox(height: 16),
            const Divider(height: 1, color: _cardBorder),
            Padding(
              key: _latestDetailsKey,
              padding: const EdgeInsets.only(top: 16),
              child: _buildGuidance(item),
            ),
          ],
          if (code != null && controller != null) ...[
            const SizedBox(height: 4),
            TextButton(
              key: const Key('clearGuideHistory'),
              onPressed: controller.clearLastError,
              child: const Text('Clear error history'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _catalogControls(List<ErrorGuideItem> items) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _cardBorder),
        ),
        child: TextField(
          key: const Key('errorSearchInput'),
          controller: _searchController,
          style: const TextStyle(fontSize: 14, color: Colors.white),
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search code or symptom',
            hintStyle: const TextStyle(fontSize: 13, color: _muted),
            prefixIcon: const Icon(
              Icons.search_rounded,
              size: 18,
              color: _muted,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    key: const Key('clearSearchButton'),
                    tooltip: 'Clear search',
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: _muted,
                    ),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {});
                    },
                  )
                : null,
            isDense: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 14,
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<String>(
            key: const Key('errorCategoryFilter'),
            tooltip: 'Filter by category',
            initialValue: _selectedCategory,
            onSelected: (category) =>
                setState(() => _selectedCategory = category),
            itemBuilder: (_) => _categories
                .map(
                  (category) => PopupMenuItem<String>(
                    key: Key('categoryPill_$category'),
                    value: category,
                    child: Row(
                      children: [
                        Expanded(child: Text(category)),
                        if (category == _selectedCategory)
                          const Icon(Icons.check_rounded, size: 18),
                      ],
                    ),
                  ),
                )
                .toList(),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.filter_list_rounded,
                    size: 18,
                    color: _muted,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _selectedCategory == 'All'
                          ? 'All categories'
                          : _selectedCategory,
                      style: const TextStyle(fontSize: 13, color: _muted),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: _muted,
                  ),
                ],
              ),
            ),
          ),
          Text(
            _hasFilters
                ? '${items.length} ${items.length == 1 ? 'match' : 'matches'}'
                : '${items.length} error codes',
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
          if (_hasFilters)
            TextButton(
              key: const Key('resetFiltersButton'),
              onPressed: _resetFilters,
              child: const Text('Reset filters'),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    final sheetContent = Material(
      color: const Color(0xFF121214),
      borderRadius: widget.isModal
          ? const BorderRadius.vertical(top: Radius.circular(28))
          : BorderRadius.zero,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const Key('errorGuideScroll'),
          controller: _scrollController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isModal) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 48, 20),
                  child: Text(
                    'Error Codes & Fixes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              _latestIssue(),
              const SizedBox(height: 20),
              const Text(
                'Error reference guide',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Semantics(
                expanded: _catalogOpen,
                child: TextButton(
                  key: const Key('browseErrorCatalog'),
                  onPressed: () => setState(() => _catalogOpen = !_catalogOpen),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                  child: Row(
                    children: [
                      Icon(
                        _catalogOpen
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _catalogOpen
                              ? 'Hide reference guide'
                              : 'Browse all errors',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_catalogOpen) ...[
                const SizedBox(height: 8),
                _catalogControls(items),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(Icons.search_off_rounded, size: 28, color: _muted),
                        SizedBox(height: 10),
                        Text(
                          'No matching error codes found',
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Try another code, symptom, or category.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: _muted),
                        ),
                      ],
                    ),
                  )
                else
                  ...items.map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildErrorCard(
                        item,
                        _expandedCodes.contains(item.code),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!widget.isModal) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox.expand(child: sheetContent),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.90,
            maxWidth: 720,
          ),
          child: Stack(
            children: [
              sheetContent,
              Positioned(
                top: 10,
                right: 12,
                child: Material(
                  color: _panel,
                  borderRadius: BorderRadius.circular(24),
                  child: IconButton(
                    key: const Key('closeErrorGuideButton'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, color: _muted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(ErrorGuideItem item, bool isExpanded) => Material(
    key: Key('errorTile_${item.code}'),
    color: _panel,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: isExpanded ? _accent.withValues(alpha: 0.4) : _cardBorder,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: isExpanded,
          child: InkWell(
            onTap: () => setState(() {
              if (!_expandedCodes.add(item.code)) {
                _expandedCodes.remove(item.code);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${item.code} · ${item.category}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: _muted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: _muted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded) ...[
          const Divider(height: 1, color: _cardBorder),
          Padding(
            padding: const EdgeInsets.all(14),
            child: _buildGuidance(item),
          ),
        ],
      ],
    ),
  );

  Widget _buildGuidance(ErrorGuideItem item) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Why this happens',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: _muted,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        item.cause,
        style: const TextStyle(
          fontSize: 13,
          color: Color(0xFFE5E5EA),
          height: 1.45,
        ),
      ),
      const SizedBox(height: 18),
      const Text(
        'What to try',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: _accent,
        ),
      ),
      const SizedBox(height: 10),
      ...item.steps.asMap().entries.map(
        (entry) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '${entry.key + 1}.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: _muted,
                    height: 1.45,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  entry.value,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFE5E5EA),
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Keep in mind',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: _muted,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        item.proTip,
        style: const TextStyle(fontSize: 12, color: _muted, height: 1.45),
      ),
    ],
  );
}

class _IndentedDivider extends StatelessWidget {
  const _IndentedDivider();

  @override
  Widget build(BuildContext context) => const Divider(
    height: 1,
    thickness: 1,
    indent: 62,
    endIndent: 0,
    color: _cardBorder,
  );
}

class _LegalDocumentSheet extends StatelessWidget {
  const _LegalDocumentSheet({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Color(0xFF121214),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: _cardBorder),
          left: BorderSide(color: _cardBorder),
          right: BorderSide(color: _cardBorder),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: _cardBorder,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('closeLegalSheetButton'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, color: _muted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _cardBorder),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: SelectableText(
                    content,
                    style: const TextStyle(
                      color: Color(0xFFE5E5EA),
                      fontSize: 13.5,
                      height: 1.55,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
