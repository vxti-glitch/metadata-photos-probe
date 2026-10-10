import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'editor_app.dart';
import 'editor_controller.dart';
import 'legal_documents.dart';
import 'media_bridge.dart';

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
                if (controller.lastErrorCode != null) ...[
                  _buildSectionHeader('RECENT ERROR DETECTED'),
                  const SizedBox(height: 8),
                  _buildRecentErrorBanner(context),
                  const SizedBox(height: 24),
                ],
                _buildSectionHeader('HELP & TROUBLESHOOTING'),
                const SizedBox(height: 8),
                _buildTroubleshootingCard(context),
                const SizedBox(height: 24),
                _buildMediaEngineCard(context),
                const SizedBox(height: 24),
                _buildSectionHeader('DATA & STORAGE'),
                const SizedBox(height: 8),
                _buildDataStorageCard(context),
                const SizedBox(height: 24),
                _buildSectionHeader('SYSTEM HEALTH & DIAGNOSTICS'),
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

  Widget _buildRecentErrorBanner(BuildContext context) {
    final code = controller.lastErrorCode!;
    final item = kErrorGuideCatalog.firstWhere(
      (e) => e.code == code,
      orElse: () => ErrorGuideItem(
        code: code,
        title: 'Unexpected Processing Error',
        category: 'System',
        cause:
            controller.lastErrorMessage ??
            'An unexpected error occurred during processing.',
        steps: const ['Tap View Fix & Guide for diagnostic troubleshooting.'],
        proTip: 'Ensure your media uses a standard format.',
      ),
    );
    final errorText = controller.lastErrorMessage != null
        ? simplifyUserError(controller.lastErrorMessage!)
        : item.cause;

    return Container(
      key: const Key('recentErrorBanner'),
      decoration: BoxDecoration(
        color: const Color(0xFF261215),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF591C22), width: 1.2),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFF38151A),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF75242C)),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: Color(0xFFFF453A),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          key: const Key('recentErrorCodeBadge'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF38151A),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFF75242C)),
                          ),
                          child: Text(
                            code,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFFF9B9B),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'ACTIVE FIX AVAILABLE',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFFF453A),
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('dismissRecentErrorButton'),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Color(0xFFFFB4AB),
                ),
                tooltip: 'Dismiss alert',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => controller.clearLastError(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E0E10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF40161B)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lightbulb_outline_rounded,
                  size: 15,
                  color: Color(0xFFFF9B9B),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    errorText,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFFFD4CE),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('viewRecentErrorFixButton'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5A1C22),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFF8B2B35)),
                ),
              ),
              onPressed: () =>
                  _openErrorGuideSheet(context, highlightedCode: code),
              icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
              label: const Text(
                'View Fix & Diagnostic Steps',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
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
              ? 'Active fix for ${controller.lastErrorCode} available'
              : 'Catalog of 8 error codes with step-by-step solutions',
          trailing: hasActiveError
              ? _buildPill(
                  text: 'ACTIVE FIX',
                  bgColor: const Color(0xFF38151A),
                  borderColor: const Color(0xFF75242C),
                  textColor: const Color(0xFFFF9B9B),
                )
              : _buildPill(
                  text: '8 CODES',
                  bgColor: const Color(0xFF1E2838),
                  borderColor: const Color(0xFF334A6E),
                  textColor: const Color(0xFF9CB5FF),
                ),
          onTap: () => _openErrorGuideSheet(
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
          subtitle: 'Preventing app-origin attribution stamps',
          trailing: const Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: _muted,
          ),
          onTap: () => _showExplanationDialog(
            context,
            title: 'Photos Attribution Guide',
            body:
                'Why does Photos show "Saved from Metadata Editor"?\n\n'
                'When third-party apps write directly into the Photos database using Apple\'s PHAssetChangeRequest, iOS automatically stamps the writing application as the asset\'s origin in Photos info panels.\n\n'
                'How to prevent attribution stamps:\n'
                '1. Tap "Export to Files" to save clean, standalone media directly to iCloud Drive or On My iPhone.\n'
                '2. In the iOS Files app, tap Share > Save Image / Save Video, or AirDrop the file to your device.\n'
                '3. Files and AirDrop imports enter Photos as native user assets with zero third-party attribution.',
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
        key: const Key('photosAccessHealthRow'),
        icon: Icons.photo_library_outlined,
        iconColor: _activeGreen,
        title: 'Photos Access',
        subtitle: 'Apple Photos library read/write authorization',
        trailing: _buildPill(
          text: 'GRANTED',
          bgColor: _activeGreenBg,
          borderColor: _activeGreenBorder,
          textColor: _activeGreen,
        ),
      ),
      const _IndentedDivider(),
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

  void _openErrorGuideSheet(BuildContext context, {String? highlightedCode}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ErrorGuideSheet(highlightedCode: highlightedCode),
    );
  }
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
      'Tap "Match iPhone" or apply a camera profile to automatically generate valid timestamps.',
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
    proTip: 'Sharing an address or dropped pin from Apple Maps copies standard decimal coordinates directly to your clipboard.',
  ),
  ErrorGuideItem(
    code: 'ERR_MEDIA_INTEGRITY',
    title: 'Conflicting Legacy Metadata',
    category: 'Integrity',
    cause: 'The imported file contains non-standard social media tags, Adobe XMP packets, or third-party editing markers that conflict with camera profiles.',
    steps: [
      'Apply a researched Camera Profile (e.g. iPhone 15 Pro) to cleanly override old container tags.',
      'In the metadata form, toggle conflicting legacy fields to "Remove".',
      'Tap "Process File" again to write a unified, verified ISO/QuickTime container.',
    ],
    proTip: 'ProbeCore restructures container atoms in-place without re-encoding media streams, guaranteeing 100% video bitstream preservation.',
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
    cause: 'Export or Share was invoked before generating a processed copy from the current editing session.',
    steps: [
      'Scroll to the bottom of the editor view.',
      'Tap the blue "Process File" button to generate your clean copy.',
      'Wait for the green "Ready" banner to appear, then tap "Export to Files" or "Share / Save to Photos".',
    ],
    proTip: 'In batch mode, tap "Process All Files" to generate clean copies for the entire queue before exporting.',
  ),
  ErrorGuideItem(
    code: 'ERR_PHOTOS_ACCESS',
    title: 'Photos Library Permission Denied',
    category: 'System',
    cause: 'iOS privacy settings have restricted Metadata Editor from accessing images or videos in your photo library.',
    steps: [
      'Open the iOS Settings app on your device.',
      'Scroll down to "Metadata Editor" (or navigate to Privacy & Security > Photos).',
      'Select Photos and change access to "Full Access".',
      'Return to Metadata Editor and re-import your media.',
    ],
    proTip: 'Importing media directly from the Files app does not require photo library permissions.',
  ),
  ErrorGuideItem(
    code: 'ERR_STORAGE_FULL',
    title: 'Insufficient Disk Space',
    category: 'Storage',
    cause: 'Device storage is too low to write temporary media working copies and container buffers during processing.',
    steps: [
      'In Metadata Editor Settings, scroll to Data & Storage and tap "Clear Media Cache".',
      'Open iOS Settings > General > iPhone Storage to verify at least 1–2 GB of available free storage.',
      'Restart the app and retry processing.',
    ],
    proTip: 'Clearing the media cache safely purges temporary sandbox files without touching your originals in Photos or Files.',
  ),
  ErrorGuideItem(
    code: 'ERR_UNSUPPORTED_MEDIA',
    title: 'Unsupported Container or Codec',
    category: 'System',
    cause: 'The imported file uses an unrecognized container wrapper, proprietary codec, or corrupted header (e.g. MKV, AVI, WebM).',
    steps: [
      'Ensure media uses standard formats: JPEG, PNG, HEIC, MP4, or QuickTime MOV.',
      'Verify video tracks use standard H.264 (AVC) or H.265 (HEVC) compression.',
      'For downloaded or transcoded clips, re-mux to MP4 before importing.',
    ],
    proTip: 'ProbeCore inspects container atoms directly. Files must contain valid moov, trak, and mdia atoms for processing.',
  ),
];

class _ErrorGuideSheet extends StatefulWidget {
  const _ErrorGuideSheet({this.highlightedCode});

  final String? highlightedCode;

  @override
  State<_ErrorGuideSheet> createState() => _ErrorGuideSheetState();
}

class _ErrorGuideSheetState extends State<_ErrorGuideSheet> {
  static const _categories = [
    'All',
    'Dates',
    'Location',
    'Integrity',
    'System',
    'Storage',
  ];

  late final TextEditingController _searchController;
  String _selectedCategory = 'All';
  late final Set<String> _expandedCodes;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _expandedCodes = {
      if (widget.highlightedCode != null)
        widget.highlightedCode!
      else
        'ERR_DATE_FMT',
    };
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ErrorGuideItem> get _filteredItems {
    final query = _searchController.text.trim().toLowerCase();
    final items = kErrorGuideCatalog.where((item) {
      final categoryMatches =
          _selectedCategory == 'All' || item.category == _selectedCategory;
      if (!categoryMatches) return false;
      if (query.isEmpty) return true;
      return item.code.toLowerCase().contains(query) ||
          item.title.toLowerCase().contains(query) ||
          item.cause.toLowerCase().contains(query) ||
          item.proTip.toLowerCase().contains(query) ||
          item.steps.any((s) => s.toLowerCase().contains(query));
    }).toList();

    if (widget.highlightedCode != null) {
      final highlightIndex = items.indexWhere(
        (it) => it.code == widget.highlightedCode,
      );
      if (highlightIndex > 0) {
        final highlighted = items.removeAt(highlightIndex);
        items.insert(0, highlighted);
      }
    }

    return items;
  }

  void _toggleExpanded(String code) {
    setState(() {
      if (_expandedCodes.contains(code)) {
        _expandedCodes.remove(code);
      } else {
        _expandedCodes.add(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.90;
    final items = _filteredItems;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 720),
        child: Container(
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
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
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
                        child: const Icon(
                          Icons.menu_book_rounded,
                          size: 18,
                          color: _accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Error Reference Guide',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '8 error codes with diagnostic fixes',
                              style: TextStyle(fontSize: 12, color: _muted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('closeErrorGuideButton'),
                        tooltip: 'Close',
                        icon: const Icon(Icons.close_rounded, color: _muted),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _cardBorder),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Container(
                    height: 40,
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
                        hintText: 'Search code, keyword, or symptom...',
                        hintStyle: const TextStyle(
                          fontSize: 13,
                          color: _subtle,
                        ),
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
                                  size: 16,
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
                          vertical: 11,
                        ),
                      ),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: _categories.map((cat) {
                      final isSelected = _selectedCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Semantics(
                          selected: isSelected,
                          button: true,
                          child: InkWell(
                            key: Key('categoryPill_$cat'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () =>
                                setState(() => _selectedCategory = cat),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected ? _accent : _panel,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected ? _accent : _cardBorder,
                                ),
                              ),
                              child: Text(
                                cat,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: isSelected ? Colors.white : _muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${items.length} of ${kErrorGuideCatalog.length} codes',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _muted,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _cardBorder),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.search_off_rounded,
                                size: 40,
                                color: _subtle,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No matching error codes found',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Try a different code or keyword',
                                style: TextStyle(fontSize: 12, color: _muted),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                key: const Key('resetFiltersButton'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: _panel,
                                  foregroundColor: _accent,
                                  side: const BorderSide(color: _cardBorder),
                                ),
                                onPressed: () {
                                  setState(() {
                                    _searchController.clear();
                                    _selectedCategory = 'All';
                                  });
                                },
                                child: const Text('Reset Filters'),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                          itemCount: items.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final isExpanded = _expandedCodes.contains(
                              item.code,
                            );
                            return _buildErrorCard(item, isExpanded);
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(ErrorGuideItem item, bool isExpanded) {
    final isHighlighted = item.code == widget.highlightedCode;
    return Container(
      key: Key('errorTile_${item.code}'),
      decoration: BoxDecoration(
        color: isHighlighted ? const Color(0xFF221418) : _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isHighlighted
              ? const Color(0xFFFF453A)
              : (isExpanded ? _accent.withValues(alpha: 0.4) : _cardBorder),
          width: isHighlighted ? 1.5 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleExpanded(item.code),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: isHighlighted
                              ? const Color(0xFF38151A)
                              : const Color(0xFF1E2838),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isHighlighted
                                ? const Color(0xFF75242C)
                                : const Color(0xFF334A6E),
                          ),
                        ),
                        child: Text(
                          item.code,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isHighlighted
                                ? const Color(0xFFFF9B9B)
                                : const Color(0xFF9CB5FF),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isHighlighted) ...[
                        Container(
                          key: Key('justEncounteredBadge_${item.code}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF38151A),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFF75242C)),
                          ),
                          child: const Text(
                            'JUST ENCOUNTERED',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFFF9B9B),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.category,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: _muted,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: isHighlighted ? const Color(0xFFFF9B9B) : _muted,
                        size: 20,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1, color: _cardBorder),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'WHY THIS HAPPENS',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: _muted,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.cause,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFE5E5EA),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'HOW TO FIX',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: _activeGreen,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...item.steps.asMap().entries.map((entry) {
                    final stepIndex = entry.key + 1;
                    final stepText = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            margin: const EdgeInsets.only(top: 1, right: 8),
                            decoration: BoxDecoration(
                              color: _activeGreenBg,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _activeGreenBorder,
                                width: 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '$stepIndex',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: _activeGreen,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              stepText,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFFE5E5EA),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF263345)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lightbulb_outline_rounded,
                          size: 16,
                          color: Color(0xFFFFD60A),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.proTip,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFC9D1D9),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
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
