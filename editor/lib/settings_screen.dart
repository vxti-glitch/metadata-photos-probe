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
  const SettingsScreen({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _background,
    appBar: AppBar(
      backgroundColor: _background,
      elevation: 0,
      leading: IconButton(
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
                _buildIdentityHero(context),
                const SizedBox(height: 28),
                _buildSectionHeader('GENERAL'),
                const SizedBox(height: 8),
                _buildGeneralCard(context),
                const SizedBox(height: 24),
                _buildSectionHeader('MEDIA & ENGINE'),
                const SizedBox(height: 8),
                _buildMediaEngineCard(context),
                const SizedBox(height: 24),
                _buildSectionHeader('DATA & STORAGE'),
                const SizedBox(height: 8),
                _buildDataStorageCard(context),
                const SizedBox(height: 24),
                _buildSectionHeader('DIAGNOSTICS & ENGINE'),
                const SizedBox(height: 8),
                _buildDiagnosticsCard(context),
                const SizedBox(height: 32),
                _buildFooter(),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildIdentityHero(BuildContext context) => Center(
    child: Column(
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _cardBorder, width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const MetadataMark(size: 48),
        ),
        const SizedBox(height: 12),
        const Text(
          AppBrand.name,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'by ${AppBrand.developer}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _accent,
            letterSpacing: 0.1,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _cardBorder),
          ),
          child: Text(
            'Version ${AppBrand.version}',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _muted,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    ),
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
        onTap: () => controller.openWebsite(),
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

  Widget _buildMediaEngineCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('photosWorkflowRow'),
        icon: Icons.photo_library_outlined,
        iconColor: _activeGreen,
        title: 'The Photos Workflow',
        subtitle: 'Manual Files & Safari export workflow',
        trailing: _buildPill(
          text: 'ACTIVE',
          bgColor: _activeGreenBg,
          borderColor: _activeGreenBorder,
          textColor: _activeGreen,
        ),
        onTap: () => _showExplanationDialog(
          context,
          title: 'The Photos Workflow',
          body:
              'Direct Photos library modification can inject app-origin attribution or trigger unwanted system alterations.\n\n'
              'To guarantee immutable camera originals and maintain uncompromised attribution independence, Metadata Editor saves processed copies to the Files app. From Files, you can seamlessly import to iCloud Photos or your photo library on your own terms.',
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
        subtitle: 'JPEG · PNG · HEIC · MP4 · MOV',
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
        title: 'Temporary Media Cache',
        subtitle: 'Clear sandboxed working copies & outputs',
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
          onPressed: () => _confirmClearCache(context),
          child: const Text(
            'Clear',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        onTap: () => _confirmClearCache(context),
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
          onPressed: () => _confirmResetPresets(context),
          child: const Text(
            'Reset',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        onTap: () => _confirmResetPresets(context),
      ),
    ],
  );

  Widget _buildDiagnosticsCard(BuildContext context) => _buildCard(
    children: [
      _buildRow(
        key: const Key('engineDiagnosticsRow'),
        icon: Icons.memory_rounded,
        iconColor: _activeGreen,
        title: 'Swift Media Engine',
        subtitle: '${AppBrand.engineCore} · Sandboxed local engine',
        trailing: const Icon(
          Icons.check_rounded,
          size: 18,
          color: _activeGreen,
        ),
      ),
      const _IndentedDivider(),
      _buildRow(
        key: const Key('privacyGuaranteeRow'),
        icon: Icons.verified_user_outlined,
        iconColor: _activeGreen,
        title: 'Privacy Guarantee',
        subtitle: '100% on-device · Zero analytics · No cloud pings',
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
      child: Row(
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
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
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
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _cardBorder),
        ),
        title: const Text(
          'Clear Media Cache?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          'Remove all app-owned temporary working files and processed copies from the local sandbox?\n\n'
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
            onPressed: () async {
              Navigator.of(context).pop();
              await controller.clearCache();
            },
            child: const Text('Clear Cache'),
          ),
        ],
      ),
    );
  }

  void _confirmResetPresets(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _cardBorder),
        ),
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
          'Default researched camera profiles remain fully available.',
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
            onPressed: () async {
              Navigator.of(context).pop();
              await controller.resetPresets();
            },
            child: const Text('Reset Presets'),
          ),
        ],
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
