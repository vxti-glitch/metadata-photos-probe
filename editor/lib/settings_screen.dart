import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'app_theme.dart';
import 'editor_app.dart';
import 'editor_controller.dart';
import 'legal_documents.dart';
import 'license_gate.dart';
import 'media_bridge.dart';
import 'settings_destinations.dart';

/// Simple grouped Settings; every tool opens a focused destination.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.isTab = false,
    this.onOpenEditor,
    this.onBack,
  });
  final EditorController controller;
  final bool isTab;
  final VoidCallback? onOpenEditor;
  final VoidCallback? onBack;

  Future<void> _license(BuildContext context) async {
    final change = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Zlarp license'),
        content: const Text(
          'Your license is active. You can remove the saved key from this device to use a different one. This does not cancel your subscription or reset your device limit on Zlarp.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove saved key'),
          ),
        ],
      ),
    );
    if (change == true && context.mounted) {
      await ZlarpLicenseGate.changeKey(context);
    }
  }

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context)
          .push<void>(MaterialPageRoute<void>(builder: (_) => page));

  void _legal(BuildContext context, String title, String content) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _LegalDocumentSheet(title: title, content: content),
      );

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        leading: isTab && onBack == null
            ? null
            : IconButton(
                key: const Key('settingsBackButton'),
                tooltip: 'Back to Home',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                onPressed: onBack ?? () => Navigator.of(context).pop(),
              ),
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
                key: const Key('settingsScroll'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (controller.statePersistenceError != null)
                    const SettingsMessage(
                      key: Key('settingsPersistenceWarning'),
                      message: 'Your latest preferences could not be saved. Try again before closing the app.',
                      isError: true,
                    ),
                  if (controller.error != null)
                    SettingsMessage(
                      key: const Key('settingsOperationError'),
                      message: controller.error!,
                      isError: true,
                    )
                  else if (controller.notice != null)
                    SettingsMessage(
                      key: const Key('settingsOperationNotice'),
                      message: controller.notice!,
                    ),
                  if (controller.busy)
                    SettingsMessage(
                      key: const Key('settingsOperationProgress'),
                      message: controller.progressLabel,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: Column(
                      children: [
                        const MetadataMark(size: 80),
                        const SizedBox(height: 14),
                        const Text(
                          AppBrand.name,
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'by ${AppBrand.developer}',
                          style: TextStyle(fontSize: 13, color: theme.muted),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Version ${AppBrand.version}',
                          style: TextStyle(fontSize: 12, color: theme.subtle),
                        ),
                      ],
                    ),
                  ),
                  settingsHeading(context, 'GENERAL'),
                  SettingsGroup(
                    children: [
                      if (ZlarpLicenseGate.available(context))
                        SettingsItem(
                          key: const Key('licenseRow'),
                          title: 'License',
                          icon: Icons.key_outlined,
                          onTap: controller.busy
                              ? null
                              : () => _license(context),
                        ),
                      SettingsItem(
                        key: const Key('appearanceRow'),
                        title: 'Appearance',
                        icon: Icons.contrast_rounded,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              switch (controller.appearance) {
                                'light' => 'Light',
                                'dark' => 'Dark',
                                _ => 'System',
                              },
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.muted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: theme.subtle,
                            ),
                          ],
                        ),
                        onTap: () => _open(
                          context,
                          AppearanceSettingsPage(controller: controller),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('localProjectsRow'),
                        title: 'Local projects',
                        icon: Icons.folder_outlined,
                        onTap: () => _open(
                          context,
                          LocalProjectsSettingsPage(
                            controller: controller,
                            onOpenEditor: onOpenEditor,
                          ),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('savedPresetsRow'),
                        title: 'Saved presets',
                        icon: Icons.bookmark_outline_rounded,
                        onTap: () => _open(
                          context,
                          SavedPresetsSettingsPage(controller: controller),
                        ),
                      ),
                    ],
                  ),
                  settingsHeading(context, 'HELP'),
                  if (controller.lastErrorCode != null) _recentIssue(context),
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        key: const Key('errorGuideRow'),
                        title: 'Error Codes & Fixes',
                        icon: Icons.menu_book_outlined,
                        onTap: () => openErrorGuidePage(
                          context,
                          controller: controller,
                          highlightedCode: controller.lastErrorCode,
                          onOpenEditor: onOpenEditor,
                        ),
                      ),
                      SettingsItem(
                        key: const Key('photosAttributionRow'),
                        title: 'Photos guide',
                        icon: Icons.photo_library_outlined,
                        onTap: () => _open(
                          context,
                          PhotosGuideSettingsPage(controller: controller),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('contactSupportRow'),
                        title: 'Contact support',
                        icon: Icons.mail_outline_rounded,
                        onTap: controller.busy
                            ? null
                            : controller.openSupportEmail,
                      ),
                    ],
                  ),
                  settingsHeading(context, 'ABOUT'),
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        key: const Key('mediaExportDetails'),
                        title: 'Media & export',
                        icon: Icons.perm_media_outlined,
                        onTap: () => _open(
                          context,
                          MediaExportSettingsPage(controller: controller),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('engineDetails'),
                        title: 'Diagnostics',
                        icon: Icons.monitor_heart_outlined,
                        onTap: () => _open(
                          context,
                          DiagnosticsSettingsPage(controller: controller),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('appInformationRow'),
                        title: 'App information',
                        icon: Icons.info_outline_rounded,
                        onTap: () => _open(
                          context,
                          AppInformationSettingsPage(controller: controller),
                        ),
                      ),
                      SettingsItem(
                        key: const Key('visitWebsiteRow'),
                        title: 'Visit Website',
                        icon: Icons.language_rounded,
                        onTap: controller.busy ? null : controller.openWebsite,
                      ),
                    ],
                  ),
                  SettingsGroup(
                    children: [
                      SettingsItem(
                        key: const Key('privacyPolicyRow'),
                        title: 'Privacy Policy',
                        icon: Icons.shield_outlined,
                        onTap: () => _legal(
                          context,
                          'Privacy Policy',
                          LegalDocuments.privacyPolicy,
                        ),
                      ),
                      SettingsItem(
                        key: const Key('termsOfUseRow'),
                        title: 'Terms of Use',
                        icon: Icons.description_outlined,
                        onTap: () => _legal(
                          context,
                          'Terms of Use',
                          LegalDocuments.termsOfUse,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _recentIssue(BuildContext context) {
    final theme = AppTheme.of(context);
    final code = controller.lastErrorCode!;
    final entry = kErrorGuideCatalog
        .where((entry) => entry.code == code)
        .firstOrNull;
    return Container(
      key: const Key('recentErrorBanner'),
      padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: theme.errorSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.errorBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry?.title ?? 'Recent issue',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  code,
                  key: const Key('recentErrorCodeBadge'),
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.error,
                    fontFamily: 'monospace',
                  ),
                ),
                TextButton(
                  key: const Key('viewRecentErrorFixButton'),
                  onPressed: () => openErrorGuidePage(
                    context,
                    controller: controller,
                    highlightedCode: code,
                    onOpenEditor: onOpenEditor,
                  ),
                  child: const Text('View diagnostic steps'),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('dismissRecentErrorButton'),
            tooltip: 'Clear error history',
            onPressed: controller.clearLastError,
            icon: Icon(Icons.close_rounded, color: theme.muted, size: 18),
          ),
        ],
      ),
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
    final failedChecks = code == 'ERR_MEDIA_INTEGRITY'
        ? safeIntegrityCheckLabels(controller?.lastErrorMessage)
        : const <String>[];
    return Container(
      key: const Key('latestIssueCard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.of(context).surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasIssue
              ? AppTheme.of(context).errorBorder
              : AppTheme.of(context).border,
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
                color: hasIssue
                    ? AppTheme.of(context).error
                    : AppTheme.of(context).muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      code == null ? 'No recent errors' : 'Latest issue',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.of(context).muted,
                      ),
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
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppTheme.of(context).muted,
            ),
          ),
          if (code != null) ...[
            const SizedBox(height: 8),
            Text(
              'Code: $code',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppTheme.of(context).muted,
              ),
            ),
          ],
          if (failedChecks.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Failed checks',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.of(context).muted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              failedChecks.join(', '),
              key: const Key('safeFailedChecks'),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppTheme.of(context).text,
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
            Text(
              'This code has no catalog entry. Keep the original and share the code with the developer; avoid sharing private media or location data.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.of(context).muted,
                height: 1.4,
              ),
            ),
          ],
          if (_latestExpanded && item != null) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: AppTheme.of(context).border),
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
          color: AppTheme.of(context).surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.of(context).border),
        ),
        child: TextField(
          key: const Key('errorSearchInput'),
          controller: _searchController,
          style: TextStyle(fontSize: 14, color: AppTheme.of(context).text),
          textInputAction: TextInputAction.search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search code or symptom',
            hintStyle: TextStyle(
              fontSize: 13,
              color: AppTheme.of(context).muted,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 18,
              color: AppTheme.of(context).muted,
            ),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    key: const Key('clearSearchButton'),
                    tooltip: 'Clear search',
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: AppTheme.of(context).muted,
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
                  Icon(
                    Icons.filter_list_rounded,
                    size: 18,
                    color: AppTheme.of(context).muted,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _selectedCategory == 'All'
                          ? 'All categories'
                          : _selectedCategory,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.of(context).muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: AppTheme.of(context).muted,
                  ),
                ],
              ),
            ),
          ),
          Text(
            _hasFilters
                ? '${items.length} ${items.length == 1 ? 'match' : 'matches'}'
                : '${items.length} error codes',
            style: TextStyle(fontSize: 12, color: AppTheme.of(context).muted),
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
      color: AppTheme.of(context).background,
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
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.search_off_rounded,
                          size: 28,
                          color: AppTheme.of(context).muted,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'No matching error codes found',
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Try another code, symptom, or category.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.of(context).muted,
                          ),
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
                  color: AppTheme.of(context).surface,
                  borderRadius: BorderRadius.circular(24),
                  child: IconButton(
                    key: const Key('closeErrorGuideButton'),
                    tooltip: 'Close',
                    icon: Icon(
                      Icons.close_rounded,
                      color: AppTheme.of(context).muted,
                    ),
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
    color: AppTheme.of(context).surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: isExpanded
            ? AppTheme.of(context).accent.withValues(alpha: 0.4)
            : AppTheme.of(context).border,
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
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.of(context).muted,
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
                    color: AppTheme.of(context).muted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded) ...[
          Divider(height: 1, color: AppTheme.of(context).border),
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
      Text(
        'Why this happens',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.of(context).muted,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        item.cause,
        style: TextStyle(
          fontSize: 13,
          color: AppTheme.of(context).text,
          height: 1.45,
        ),
      ),
      const SizedBox(height: 18),
      Text(
        'What to try',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.of(context).accent,
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
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.of(context).muted,
                    height: 1.45,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.of(context).text,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Keep in mind',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppTheme.of(context).muted,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        item.proTip,
        style: TextStyle(
          fontSize: 12,
          color: AppTheme.of(context).muted,
          height: 1.45,
        ),
      ),
    ],
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
      key: const Key('legalDocumentSheet'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: AppTheme.of(context).surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: AppTheme.of(context).border),
          left: BorderSide(color: AppTheme.of(context).border),
          right: BorderSide(color: AppTheme.of(context).border),
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
                  color: AppTheme.of(context).border,
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
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.of(context).text,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('closeLegalSheetButton'),
                    tooltip: 'Close',
                    icon: Icon(
                      Icons.close_rounded,
                      color: AppTheme.of(context).muted,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppTheme.of(context).border),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  child: SelectableText(
                    content,
                    style: TextStyle(
                      color: AppTheme.of(context).text,
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
