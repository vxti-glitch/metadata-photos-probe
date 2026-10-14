import 'package:flutter/material.dart';

import 'app_brand.dart';
import 'app_theme.dart';
import 'editor_controller.dart';
import 'media_models.dart';

/// A normal grouped Settings destination that keeps the editor mounted beneath it.
class SettingsDestination extends StatelessWidget {
  const SettingsDestination({
    super.key,
    required this.title,
    required this.controller,
    required this.builder,
    this.actions,
  });
  final String title;
  final EditorController controller;
  final List<Widget> Function(BuildContext context) builder;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title, style: const TextStyle(fontSize: 18)),
      leading: IconButton(
        key: const Key('settingsDestinationBack'),
        tooltip: 'Back to Settings',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
      ),
      actions: actions,
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (controller.statePersistenceError != null)
                  SettingsMessage(
                    message: 'This preference could not be saved. Try again before closing the app.',
                    isError: true,
                    key: const Key('settingsPersistenceWarning'),
                  ),
                if (controller.error != null)
                  SettingsMessage(message: controller.error!, isError: true),
                if (controller.busy)
                  SettingsMessage(message: controller.progressLabel)
                else if (controller.notice != null)
                  SettingsMessage(message: controller.notice!),
                ...builder(context),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SettingsMessage extends StatelessWidget {
  const SettingsMessage({
    super.key,
    required this.message,
    this.isError = false,
  });
  final String message;
  final bool isError;
  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? theme.errorSurface : theme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isError ? theme.errorBorder : theme.border),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: isError ? theme.error : theme.text,
          height: 1.4,
        ),
      ),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    decoration: BoxDecoration(
      color: AppTheme.of(context).surface,
      borderRadius: BorderRadius.circular(20),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Divider(height: 1, indent: 54, color: AppTheme.of(context).border),
          children[index],
        ],
      ],
    ),
  );
}

class SettingsItem extends StatelessWidget {
  const SettingsItem({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onTap,
    this.trailing,
    this.destructive = false,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;
  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stackTrailing =
                trailing != null &&
                (constraints.maxWidth < 320 ||
                    MediaQuery.textScalerOf(context).scale(15) > 21);
            final details = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 21,
                    color: destructive ? theme.error : theme.muted,
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: destructive ? theme.error : theme.text,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.muted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null && !stackTrailing) ...[
                  const SizedBox(width: 10),
                  trailing!,
                ] else if (trailing == null && onTap != null) ...[
                  const SizedBox(width: 10),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: theme.subtle,
                  ),
                ],
              ],
            );
            if (!stackTrailing) return details;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                details,
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.only(left: icon == null ? 0 : 35),
                  child: trailing,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Widget settingsHeading(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
  child: Text(
    text,
    style: TextStyle(
      color: AppTheme.of(context).muted,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
  ),
);

Widget settingsParagraph(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
  child: Text(
    text,
    style: TextStyle(
      color: AppTheme.of(context).muted,
      height: 1.5,
      fontSize: 13,
    ),
  ),
);

Future<void> confirmSettingsAction(
  BuildContext context,
  EditorController controller, {
  required String title,
  required String body,
  required String action,
  required Future<void> Function() onConfirm,
  Key? confirmKey,
}) => showDialog<void>(
  context: context,
  builder: (context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => AlertDialog(
      title: Text(title),
      content: Text(body),
      scrollable: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: confirmKey,
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.of(context).error,
          ),
          onPressed: controller.busy || !controller.ready
              ? null
              : () async {
                  Navigator.of(context).pop();
                  await onConfirm();
                },
          child: Text(action),
        ),
      ],
    ),
  ),
);

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Appearance',
    controller: controller,
    builder: (context) => [
      SettingsGroup(
        children: [
          for (final value in const ['system', 'light', 'dark'])
            SettingsItem(
              key: Key('appearance_$value'),
              title: switch (value) {
                'system' => 'System',
                'light' => 'Light',
                _ => 'Dark',
              },
              subtitle: value == 'system'
                  ? 'Follow your phone’s appearance'
                  : null,
              icon: switch (value) {
                'system' => Icons.brightness_auto_outlined,
                'light' => Icons.light_mode_outlined,
                _ => Icons.dark_mode_outlined,
              },
              onTap: () => controller.setAppearance(value),
              trailing: Semantics(
                selected: controller.appearance == value,
                child: Icon(
                  controller.appearance == value ? Icons.check_rounded : null,
                  color: AppTheme.of(context).accent,
                  size: 22,
                ),
              ),
            ),
        ],
      ),
      settingsParagraph(
        context,
        'Your choice is remembered. Changing appearance keeps your current edit and prepared files.',
      ),
    ],
  );
}

class LocalProjectsSettingsPage extends StatelessWidget {
  const LocalProjectsSettingsPage({
    super.key,
    required this.controller,
    this.onOpenEditor,
  });
  final EditorController controller;
  final VoidCallback? onOpenEditor;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Local projects',
    controller: controller,
    builder: (context) => [
      settingsParagraph(
        context,
        'Private working copies stay on this device. Deleting a project does not delete Photos originals, provider files or copies you already exported.',
      ),
      if (controller.sessions.isEmpty)
        const SettingsGroup(
          children: [
            SettingsItem(
              title: 'No local projects',
              subtitle: 'Select photos or files on Home to start.',
            ),
          ],
        )
      else
        SettingsGroup(
          children: [
            for (final session in controller.sessions)
              SettingsItem(
                key: Key('localProject_${session.id}'),
                title: session.displayName,
                subtitle:
                    '${session.inspection.kind.name.toUpperCase()} · ${session.processing == null ? 'Original working copy' : 'Edited copy available; review verification before export'}',
                icon:
                    session.inspection.kind == MediaKind.mp4 ||
                        session.inspection.kind == MediaKind.mov
                    ? Icons.movie_outlined
                    : Icons.image_outlined,
                onTap:
                    controller.busy || !controller.ready || onOpenEditor == null
                    ? null
                    : () {
                        controller.select(session);
                        Navigator.of(context).pop();
                        onOpenEditor!();
                      },
                trailing: IconButton(
                  key: Key('deleteLocalProject_${session.id}'),
                  tooltip: 'Delete local project',
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: AppTheme.of(context).error,
                  ),
                  onPressed: controller.busy || !controller.ready
                      ? null
                      : () => confirmSettingsAction(
                          context,
                          controller,
                          title: 'Delete Local Project?',
                          body: 'Remove this project and its private working copies. Originals and already exported copies stay unchanged.',
                          action: 'Delete project',
                          onConfirm: () => controller.delete(session),
                        ),
                ),
              ),
          ],
        ),
      SettingsGroup(
        children: [
          SettingsItem(
            key: const Key('clearCacheButton'),
            title: 'Clear all local projects',
            icon: Icons.delete_sweep_outlined,
            destructive: true,
            onTap: controller.busy || !controller.ready
                ? null
                : () => confirmSettingsAction(
                    context,
                    controller,
                    title: 'Clear Local Projects?',
                    body: 'Remove all private working copies and project history. Photos originals, provider files, published files in Processed Media and already exported copies remain unchanged.',
                    action: 'Clear projects',
                    confirmKey: const Key('confirmClearCacheButton'),
                    onConfirm: controller.clear,
                  ),
          ),
        ],
      ),
      if (controller.queue.any((item) => item.status != 'completed'))
        SettingsGroup(
          children: [
            SettingsItem(
              key: const Key('resumeStoredBatch'),
              title: 'Unfinished batch',
              subtitle: 'Review the saved results and retry unfinished files.',
              icon: Icons.refresh_rounded,
              onTap:
                  controller.busy || !controller.ready || onOpenEditor == null
                  ? null
                  : () {
                      controller.resumeStoredBatch();
                      Navigator.of(context).pop();
                      onOpenEditor!();
                    },
            ),
          ],
        ),
    ],
  );
}

class SavedPresetsSettingsPage extends StatelessWidget {
  const SavedPresetsSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Saved presets',
    controller: controller,
    builder: (context) => [
      settingsParagraph(
        context,
        'Save your current edits as a preset from the editor. Import a preset here, or export an existing one to Files.',
      ),
      SettingsGroup(
        children: [
          SettingsItem(
            key: const Key('importPresetFromSettings'),
            title: 'Import preset',
            icon: Icons.file_download_outlined,
            onTap: controller.busy || !controller.ready
                ? null
                : controller.importPreset,
          ),
        ],
      ),
      if (controller.presets.isEmpty)
        const SettingsGroup(
          children: [
            SettingsItem(
              title: 'No saved presets',
              subtitle: 'Your saved camera profiles and edit recipes will appear here.',
            ),
          ],
        )
      else
        SettingsGroup(
          children: [
            for (final preset in controller.presets)
              SettingsItem(
                key: Key('settingsPreset_${preset.id}'),
                title: preset.name,
                subtitle: preset.recipe == null
                    ? 'Saved metadata edits'
                    : 'Camera and randomization recipe',
                icon: Icons.bookmark_outline_rounded,
                trailing: PopupMenuButton<String>(
                  key: Key('settingsPresetMenu_${preset.id}'),
                  tooltip: 'Preset actions',
                  enabled: controller.ready && !controller.busy,
                  onSelected: (action) {
                    if (action == 'export') {
                      controller.exportPreset(preset);
                    } else {
                      confirmSettingsAction(
                        context,
                        controller,
                        title: 'Delete Preset?',
                        body: 'Remove this saved preset. Your media and exported preset files remain unchanged.',
                        action: 'Delete preset',
                        onConfirm: () => controller.deletePreset(preset),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'export',
                      child: Text('Export to Files'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete preset'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      SettingsGroup(
        children: [
          SettingsItem(
            key: const Key('resetPresetsButton'),
            title: 'Reset saved presets',
            icon: Icons.restart_alt_rounded,
            destructive: true,
            onTap: controller.busy || !controller.ready
                ? null
                : () => confirmSettingsAction(
                    context,
                    controller,
                    title: 'Reset Saved Presets?',
                    body: 'Remove your saved presets and remembered camera choice. Your media and exported preset files remain unchanged.',
                    action: 'Reset presets',
                    confirmKey: const Key('confirmResetPresetsButton'),
                    onConfirm: controller.resetPresets,
                  ),
          ),
        ],
      ),
    ],
  );
}

class PhotosGuideSettingsPage extends StatelessWidget {
  const PhotosGuideSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Photos guide',
    controller: controller,
    builder: (context) => [
      SettingsGroup(
        children: const [
          SettingsItem(
            title: '1. Create an edited copy',
            subtitle: 'Review your changes, then create the copy. Originals remain unchanged.',
          ),
          SettingsItem(
            title: '2. Export to Files',
            subtitle: 'Choose a folder you can find again. Warnings about other file details allow export. Incomplete checks require your acknowledgment; failed media or requested-edit checks block export.',
          ),
          SettingsItem(
            title: '3. Upload through Safari',
            subtitle: 'On your phone, open iCloud Photos in Safari, sign in yourself and upload the exported file using the available upload control. You can also upload through iCloud Photos from your computer.',
          ),
          SettingsItem(
            title: '4. Wait for Photos to sync',
            subtitle: 'Use the same Apple Account with iCloud Photos enabled. Confirm the copy appears, then check its information on your phone.',
          ),
        ],
      ),
      settingsHeading(context, 'Photos labels'),
      settingsParagraph(
        context,
        'Embedded metadata and Photos app-origin labels are separate. Editing camera fields does not prove that a Photos attribution label is absent. Apple controls the resulting Photos presentation. This app does not directly write processed copies to Photos or change its database.',
      ),
      SettingsGroup(
        children: [
          SettingsItem(
            key: const Key('openICloudFromSettings'),
            title: 'Open iCloud Photos',
            icon: Icons.open_in_browser_rounded,
            onTap: controller.busy ? null : controller.openICloud,
          ),
        ],
      ),
    ],
  );
}

class MediaExportSettingsPage extends StatelessWidget {
  const MediaExportSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Media & export',
    controller: controller,
    builder: (context) => [
      SettingsGroup(
        children: [
          SettingsItem(
            key: const Key('supportedContainersRow'),
            title: 'Supported formats',
            icon: Icons.perm_media_outlined,
            subtitle: controller.ready
                ? '${controller.capabilities!.formats.map((f) => f.toUpperCase()).join(' · ')}\nField and file-layout limits apply.'
                : 'Format support is available after startup.',
          ),
          const SettingsItem(
            key: Key('preserveOriginalsRow'),
            title: 'Originals stay unchanged',
            icon: Icons.lock_outline_rounded,
            subtitle: 'Edits create a separate local copy. Source media remains bit-for-bit identical; conversion or re-encoding is not used as a fallback.',
          ),
          const SettingsItem(
            title: 'Verification before export',
            icon: Icons.verified_outlined,
            subtitle: 'Each copy is checked before export. Changes to other file details show a warning and allow export. Failed media or requested-edit checks block export. Limited checks still require your acknowledgment.',
          ),
          const SettingsItem(
            title: 'Where your copy goes',
            icon: Icons.folder_outlined,
            subtitle: 'Fully verified copies may appear in the app’s Files folder. Export to Files lets you choose a destination. Share opens the system share sheet; neither action confirms a Photos upload.',
          ),
          const SettingsItem(
            title: 'Live Photos',
            icon: Icons.motion_photos_off_outlined,
            subtitle: 'Paired Live Photos are outside the editor’s scope. Use a still image with Live turned off. The app does not flatten Live Photos or drop video tracks.',
          ),
        ],
      ),
    ],
  );
}

class DiagnosticsSettingsPage extends StatelessWidget {
  const DiagnosticsSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'Diagnostics',
    controller: controller,
    builder: (context) => [
      SettingsGroup(
        children: [
          SettingsItem(
            title: 'Swift Media Engine',
            icon: Icons.memory_rounded,
            subtitle:
                '${AppBrand.engineCore} · ${controller.ready ? 'Ready' : 'Not ready'} · Sandboxed local engine',
            trailing: Icon(
              controller.ready ? Icons.check_rounded : Icons.hourglass_empty,
              color: controller.ready
                  ? AppTheme.of(context).success
                  : AppTheme.of(context).muted,
            ),
          ),
          const SettingsItem(
            title: 'Photos Access',
            icon: Icons.photo_library_outlined,
            subtitle: 'Requested when importing from Photos; limited access is supported',
            trailing: Text('ON IMPORT'),
          ),
          const SettingsItem(
            title: 'Storage Sandbox',
            icon: Icons.folder_special_outlined,
            subtitle: 'Temporary working copies isolated in local sandbox',
            trailing: Text('FILE-BACKED'),
          ),
          const SettingsItem(
            key: Key('privacyGuaranteeRow'),
            title: 'Privacy Guarantee',
            icon: Icons.shield_outlined,
            subtitle: 'On-device processing · No analytics · Cloud-backed imports may download',
          ),
        ],
      ),
      if (!controller.ready)
        SettingsGroup(
          children: [
            SettingsItem(
              key: const Key('retryStartupFromSettings'),
              title: 'Retry startup',
              icon: Icons.refresh_rounded,
              onTap: controller.busy ? null : controller.initialize,
            ),
          ],
        ),
      settingsParagraph(
        context,
        '${AppBrand.name} ${AppBrand.version} (Build ${AppBrand.buildNumber}) · © 2026 ${AppBrand.developer}',
      ),
    ],
  );
}

class AppInformationSettingsPage extends StatelessWidget {
  const AppInformationSettingsPage({super.key, required this.controller});
  final EditorController controller;
  @override
  Widget build(BuildContext context) => SettingsDestination(
    title: 'App information',
    controller: controller,
    builder: (context) => [
      SettingsGroup(
        children: const [
          SettingsItem(
            title: AppBrand.name,
            subtitle: 'by ${AppBrand.developer}',
            icon: Icons.info_outline_rounded,
          ),
          SettingsItem(
            title: 'Version',
            subtitle: '${AppBrand.version} · Build ${AppBrand.buildNumber}',
          ),
          SettingsItem(title: 'Native engine', subtitle: AppBrand.engineCore),
          SettingsItem(
            title: 'Local processing',
            subtitle: 'Media stays in local storage. No account or server is required for editing.',
          ),
        ],
      ),
    ],
  );
}
