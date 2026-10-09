import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_profiles.dart';
import 'editor_controller.dart';
import 'media_models.dart';
import 'metadata_patch.dart';
import 'metadata_dates.dart';
import 'editor_app.dart' show WorkflowNote;

/// Caller-owned text controllers must outlive the dialog's exit animation.
/// Navigator.pop completes the push future before its overlay is unmounted.
Future<T?> _ownedControllerDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}

/// Editors keep a separate explicit intent for every field. Empty text never
/// silently deletes metadata; removal is a deliberate operation.
class MetadataForm extends StatefulWidget {
  const MetadataForm({
    super.key,
    required this.controller,
    required this.session,
    this.batch = false,
  });
  final EditorController controller;
  final MediaSession session;
  final bool batch;
  @override
  State<MetadataForm> createState() => _MetadataFormState();
}

class _MetadataFormState extends State<MetadataForm>
    with SingleTickerProviderStateMixin {
  final inputs = <String, TextEditingController>{};
  final modes = <String, String>{};
  final random = Random.secure();
  late final Future<List<CameraProfile>> catalog;
  late final TabController _tabController;
  int _tabIndex = 0;
  CameraProfile? profile;
  ProfileCamera? camera;
  String? brand;
  RandomizationSettings settings = const RandomizationSettings();
  String? formError;
  MetadataPatch? profileBaseline;
  final explicitOverrides = <String>{};
  bool _appliedFeedback = false;
  Timer? _appliedTimer;
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted && _tabController.index != _tabIndex) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
    widget.controller.addListener(_refresh);
    catalog = loadCameraProfiles();
    for (final f in metadataFields) {
      final source =
          widget.session.inspection.metadata[f.key] ??
          (f.key == 'lensModel'
              ? widget.session.inspection.metadata['lens']
              : null) ??
          '';
      inputs[f.key] = TextEditingController(text: source);
      modes[f.key] = 'keep';
    }
    final patch = widget.session.processing?.metadataPatch;
    if (patch != null) _apply(patch, notify: false);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _appliedTimer?.cancel();
    _tabController.dispose();
    widget.controller.removeListener(_refresh);
    for (final c in inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  Set<String> get supported =>
      widget.controller.capabilities!.fieldsFor(widget.session.inspection.kind);
  void _apply(
    MetadataPatch patch, {
    bool notify = true,
    bool fromProfile = false,
  }) {
    profileBaseline = fromProfile ? patch : null;
    explicitOverrides.clear();
    for (final key in inputs.keys) {
      if (patch.values.containsKey(key)) {
        inputs[key]!.text = patch.values[key].toString();
        modes[key] = 'set';
      } else if (patch.removals.contains(key)) {
        modes[key] = 'remove';
      } else {
        modes[key] = 'keep';
        inputs[key]!.text =
            widget.session.inspection.metadata[key] ??
            (key == 'lensModel'
                ? widget.session.inspection.metadata['lens']
                : null) ??
            '';
      }
    }
    if (notify) setState(() {});
  }

  MetadataPatch _patch({bool allowEmpty = false, Set<String>? fields}) {
    final values = <String, Object>{};
    final removed = <String>[];
    for (final f in metadataFields) {
      if (!(fields ?? supported).contains(f.key)) continue;
      if (modes[f.key] == 'remove') {
        removed.add(f.key);
      } else if (modes[f.key] == 'set') {
        values[f.key] = MetadataPatch.parseField(f, inputs[f.key]!.text);
      }
    }
    final result = MetadataPatch(values: values, removals: removed);
    if (allowEmpty && values.isEmpty && removed.isEmpty) return result;
    final invalid = result.validate();
    if (invalid != null) throw FormatException(invalid);
    return result;
  }

  MetadataPatch _standaloneAutomaticDates(
    MetadataPatch manual,
    MediaSession source,
  ) {
    final fields = widget.controller.capabilities!.fieldsFor(
      source.inspection.kind,
    );
    if (!settings.randomizeDates) {
      return MetadataPatch(
        values: {
          for (final entry in manual.values.entries)
            if (fields.contains(entry.key)) entry.key: entry.value,
        },
        removals: manual.removals.where((k) => fields.contains(k)).toList(),
      );
    }
    final date = DateTime.now().subtract(
      Duration(seconds: random.nextInt(max(1, settings.pastDays * 86400 + 1))),
    );
    final rawGenerated = captureDatePatch(
      date,
      image: source.inspection.kind.isImage,
    );
    final kept = explicitOverrides.where((key) => modes[key] == 'keep').toSet();
    final generated = source.inspection.kind.isImage
        ? randomDatesWithKeptZones(
            rawGenerated,
            keepFields: kept,
            destinationMetadata: source.inspection.metadata,
            fixedDates: {...manual.values.keys, ...kept},
          )
        : rawGenerated;
    final values = <String, Object>{
      for (final entry in generated.values.entries)
        if (fields.contains(entry.key) &&
            !manual.removals.contains(entry.key) &&
            !(explicitOverrides.contains(entry.key) &&
                modes[entry.key] == 'keep'))
          entry.key: entry.value,
      for (final entry in manual.values.entries)
        if (fields.contains(entry.key))
          entry.key: entry.value,
    };
    return MetadataPatch(
      values: values,
      removals: manual.removals.where((k) => fields.contains(k)).toList(),
    );
  }

  MetadataPatch _profilePatch(MediaSession source) {
    final fields = widget.controller.capabilities!.fieldsFor(
      source.inspection.kind,
    );
    final patch = settings.generate(
      profile!,
      camera!,
      source.inspection.kind,
      random,
      DateTime.now(),
      supportedFields: fields,
    );
    final removals = <String>[];
    // Unknown specifications must not become an incompatible mix of two phones.
    for (final key in [
      ...profile!.clearFields,
      ...camera!.clearFields,
      'software',
      'lensMake',
      'hostComputer',
    ]) {
      if (fields.contains(key) && !patch.values.containsKey(key)) {
        removals.add(key);
      }
    }
    return MetadataPatch(values: patch.values, removals: removals);
  }

  void _settingsChanged(RandomizationSettings next) {
    try {
      final previousRecipe = profileBaseline == null
          ? null
          : _currentRecipe(_patch());
      final oldSettings = settings;
      settings = next;
      try {
        if (previousRecipe != null) {
          final generated = _profilePatch(widget.session);
          final merged = applyRecipeOverrides(
            generated,
            previousRecipe,
            supportedFields: supported,
          );
          _apply(merged, notify: false, fromProfile: true);
          profileBaseline = generated;
          explicitOverrides.addAll(
            previousRecipe.overrides?.values.keys ?? <String>[],
          );
          explicitOverrides.addAll(
            previousRecipe.overrides?.removals ?? <String>{},
          );
          explicitOverrides.addAll(previousRecipe.keepFields);
        }
      } catch (_) {
        settings = oldSettings;
        rethrow;
      }
      setState(() => formError = null);
    } on FormatException catch (e) {
      setState(() => formError = e.message);
    }
  }

  Widget _automaticDates() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: const Key('automaticDates'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: settings.randomizeDates,
        onChanged: widget.controller.busy
            ? null
            : (enabled) => _settingsChanged(
                settings.withAutomaticDates(enabled ?? false),
              ),
        title: const Text('Randomize date & time'),
        subtitle: const Text(
          'Off keeps original dates unless you set them manually.',
        ),
      ),
      if (!settings.randomizeDates)
        OutlinedButton.icon(
          key: const Key('setCaptureDate'),
          onPressed: widget.controller.busy ? null : _pickCaptureDate,
          icon: const Icon(Icons.event_outlined),
          label: const Text('Set date & time'),
        ),
    ],
  );
  Future<void> _pickCaptureDate() async {
    final text = inputs['dateTimeOriginal']!.text;
    final exif = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
        .firstMatch(text);
    final parsed = exif == null
        ? DateTime.tryParse(text)
        : DateTime(
            int.parse(exif.group(1)!),
            int.parse(exif.group(2)!),
            int.parse(exif.group(3)!),
            int.parse(exif.group(4)!),
            int.parse(exif.group(5)!),
            int.parse(exif.group(6)!),
          );
    final initial = parsed?.toLocal() ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial.year >= 1900 && initial.year <= 2100
          ? initial
          : DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final selection = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final patch = captureDatePatch(
      selection,
      image: widget.session.inspection.kind.isImage,
    );
    setState(() {
      for (final e in patch.values.entries) {
        if (!supported.contains(e.key)) continue;
        // A timezone explicitly entered in the manual editor takes precedence.
        if (e.key.startsWith('offsetTime') &&
            modes[e.key] == 'set' &&
            inputs[e.key]!.text != profileBaseline?.values[e.key]?.toString()) {
          continue;
        }
        inputs[e.key]!.text = e.value.toString();
        modes[e.key] = 'set';
        explicitOverrides.add(e.key);
      }
      formError = null;
    });
  }

  Future<void> _process() async {
    try {
      if (widget.batch) {
        final sources = widget.controller.sessions.where(
          (s) => widget.controller.batchSelection.contains(s.id),
        );
        final manual = _patch(
          allowEmpty: settings.randomizeDates,
          fields: sources
              .expand(
                (s) => widget.controller.capabilities!.fieldsFor(
                  s.inspection.kind,
                ),
              )
              .toSet(),
        );
        final patches = <String, MetadataPatch>{};
        for (final source in sources) {
          final itemManual = datesForMedia(
            manual,
            image: source.inspection.kind.isImage,
            keptOffsets: source.inspection.kind.isImage
                ? source.inspection.metadata
                : widget.session.inspection.metadata,
            keepFields: explicitOverrides
                .where((key) => modes[key] == 'keep')
                .toSet(),
          );
          if (profile != null && camera != null && profileBaseline != null) {
            final kept = explicitOverrides
                .where((key) => modes[key] == 'keep')
                .toSet();
            final fixedDates = sharedDateOffsets.keys
                .where(
                  (key) =>
                      manual.values.containsKey(key) &&
                      (explicitOverrides.contains(key) ||
                          manual.values[key] != profileBaseline!.values[key]),
                )
                .toSet();
            final rawGenerated = _profilePatch(source);
            final generated = source.inspection.kind.isImage
                ? randomDatesWithKeptZones(
                    rawGenerated,
                    keepFields: kept,
                    destinationMetadata: source.inspection.metadata,
                    fixedDates: fixedDates,
                  )
                : rawGenerated;
            final dateOverride =
                {...sharedDateOffsets.keys, ...sharedDateOffsets.values}.any(
                  (key) =>
                      manual.values.containsKey(key) &&
                      (explicitOverrides.contains(key) ||
                          manual.values[key] != profileBaseline!.values[key]),
                );
            // Manual overrides after choosing a profile are retained; newly
            // randomized small values remain independent for each batch item.
            final values = {...generated.values};
            final removals = {...generated.removals};
            final fields = widget.controller.capabilities!.fieldsFor(
              source.inspection.kind,
            );
            for (final key in fields) {
              final intent = modes[key];
              if (intent == 'keep' &&
                  (explicitOverrides.contains(key) ||
                      profileBaseline!.values.containsKey(key) ||
                      profileBaseline!.removals.contains(key))) {
                values.remove(key);
                removals.remove(key);
              } else if (itemManual.values.containsKey(key) &&
                  ((intent == 'set' &&
                          (explicitOverrides.contains(key) ||
                              manual.values[key] !=
                                  profileBaseline!.values[key])) ||
                      (dateOverride && !manual.values.containsKey(key)))) {
                values[key] = itemManual.values[key]!;
                removals.remove(key);
              } else if (intent == 'remove') {
                values.remove(key);
                removals.add(key);
              }
            }
            patches[source.id] = MetadataPatch(
              values: values,
              removals: removals,
            );
          } else {
            patches[source.id] = _standaloneAutomaticDates(itemManual, source);
          }
        }
        final sanitizedPatches = <String, MetadataPatch>{};
        for (final entry in patches.entries) {
          final source = sources.firstWhere((s) => s.id == entry.key);
          final fields = widget.controller.capabilities!.fieldsFor(
            source.inspection.kind,
          );
          sanitizedPatches[entry.key] = MetadataPatch(
            values: {
              for (final v in entry.value.values.entries)
                if (fields.contains(v.key)) v.key: v.value,
            },
            removals: entry.value.removals
                .where((k) => fields.contains(k))
                .toList(),
          );
        }
        await widget.controller.processBatch(sanitizedPatches);
      } else {
        final rawManual = _patch(allowEmpty: settings.randomizeDates);
        final kept = explicitOverrides
            .where((key) => modes[key] == 'keep')
            .toSet();
        var shaped = rawManual;
        if (profileBaseline != null && widget.session.inspection.kind.isImage) {
          final fixedDates = sharedDateOffsets.keys
              .where(
                (key) =>
                    rawManual.values.containsKey(key) &&
                    (explicitOverrides.contains(key) ||
                        rawManual.values[key] != profileBaseline!.values[key]),
              )
              .toSet();
          final withZones = MetadataPatch(
            values: {
              ...rawManual.values,
              for (final key in sharedDateOffsets.values)
                if (kept.contains(key) &&
                    !rawManual.values.containsKey(key) &&
                    profileBaseline!.values.containsKey(key))
                  key: profileBaseline!.values[key]!,
            },
            removals: rawManual.removals,
          );
          final normalized = randomDatesWithKeptZones(
            withZones,
            keepFields: kept,
            destinationMetadata: widget.session.inspection.metadata,
            fixedDates: {...fixedDates, ...kept},
          );
          shaped = MetadataPatch(
            values: {
              for (final entry in normalized.values.entries)
                if (!kept.contains(entry.key)) entry.key: entry.value,
            },
            removals: normalized.removals,
          );
        }
        final manual = datesForMedia(
          shaped,
          image: widget.session.inspection.kind.isImage,
          keptOffsets: widget.session.inspection.metadata,
          keepFields: explicitOverrides
              .where((key) => modes[key] == 'keep')
              .toSet(),
        );
        await widget.controller.processMetadata(
          profileBaseline == null
              ? _standaloneAutomaticDates(manual, widget.session)
              : manual,
        );
      }
      if (mounted) setState(() => formError = null);
    } on FormatException catch (e) {
      setState(() => formError = e.message);
    }
  }

  Future<void> _openModelSearchSheet(
    BuildContext context,
    List<CameraProfile> availableProfiles,
  ) async {
    final selected = await showModalBottomSheet<CameraProfile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191E25),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ModelSearchSheet(
        availableProfiles: availableProfiles,
        selectedProfileId: profile?.id,
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        brand = selected.brand;
        profile = selected;
        camera = profile!.cameras.first;
        _appliedFeedback = false;
        _apply(
          _profilePatch(widget.session),
          notify: false,
          fromProfile: true,
        );
      });
    }
  }

  Widget _buildProcessingResults(BuildContext context, Processing output) {
    final controller = widget.controller;
    final isMismatch = output.integrity.hasMismatch;
    final needsAck = output.integrity.needsAcknowledgment && !isMismatch;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isMismatch ? const Color(0xFF281418) : const Color(0xFF141C28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMismatch ? const Color(0xFF5A2530) : const Color(0xFF233658),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isMismatch
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: isMismatch ? Colors.redAccent : const Color(0xFF9CB5FF),
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isMismatch
                      ? 'Integrity Check Failed'
                      : (output.outputDisplayName ?? 'Processing Succeeded'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isMismatch ? Colors.redAccent : const Color(0xFFE7EDF4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1115),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Output File',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    Text(
                      '${output.inspection.kind.label} · ${output.inspection.sizeLabel}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  output.outputDisplayName ?? 'Processed copy',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: Color(0xFFE7EDF4),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Color(0xFF222B38)),
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 16, color: Color(0xFF9CB5FF)),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Saved to: On My iPhone › Metadata Editor › Processed Media',
                        style: TextStyle(fontSize: 11, color: Color(0xFF9BA6B4)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isMismatch) ...[
            const SizedBox(height: 12),
            const Text(
              'A preservation check failed. Export blocked.',
              style: TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ],
          if (needsAck) ...[
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                key: const Key('acknowledge'),
                contentPadding: EdgeInsets.zero,
                value: controller.acknowledged,
                onChanged: controller.busy
                    ? null
                    : (v) => controller.acknowledge(v ?? false),
                title: const Text(
                  'I accept the stated preservation limitations',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  output.integrity.limitations.join('\n'),
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('exportFiles'),
                  onPressed: controller.canExport ? controller.exportFiles : null,
                  icon: const Icon(Icons.folder_shared_outlined, size: 18),
                  label: const Text('Export to Files'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('shareFiles'),
                  onPressed: controller.canExport ? controller.shareFiles : null,
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('openICloud'),
            onPressed: controller.busy ? null : controller.openICloud,
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Open iCloud Photos in Safari'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Upload the exported file in Safari, then let it sync to Photos.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 11),
          ),
          const SizedBox(height: 14),
          const WorkflowNote(),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: controller.busy ? null : () => controller.select(null),
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: const Text('Process another file'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final source = widget.session;
    final output = source.processing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.batch) ...[
          Text(
            'Batch Editor',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '${controller.batchSelection.length} files selected · Settings apply across all batch items',
            style: const TextStyle(color: Color(0xFF9CB5FF), fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF141C28),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF233658)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome_motion_outlined, color: Color(0xFF9CB5FF), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Selected files: ${controller.sessions.where((s) => controller.batchSelection.contains(s.id)).map((s) => s.displayName).take(3).join(', ')}${controller.batchSelection.length > 3 ? ' +${controller.batchSelection.length - 3} more' : ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Text(
            source.displayName,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${source.inspection.kind.label} · ${source.inspection.sizeLabel}',
            style: const TextStyle(color: Colors.white60),
          ),
        ],
        if (formError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              formError!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        const SizedBox(height: 20),
        TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF9CB5FF),
          labelColor: const Color(0xFF9CB5FF),
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Presets'),
            Tab(text: 'Edit'),
          ],
        ),
        const SizedBox(height: 16),
        _tabIndex == 0 ? _presets(context) : _manual(context),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('process'),
          onPressed: controller.busy ? null : _process,
          icon: const Icon(Icons.auto_fix_high_outlined),
          label: Text(widget.batch ? 'Process ${controller.batchSelection.length} selected files' : 'Process file'),
        ),
        if (!widget.batch && output != null)
          _buildProcessingResults(context, output),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('Details'),
          children: [
            const ListTile(title: Text('Original metadata')),
            for (final e in {
              ...source.inspection.metadata,
              ...source.inspection.structure,
              ...source.details,
            }.entries)
              ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: SelectableText(e.value),
              ),
            for (final note in [...source.notes, ...source.inspection.notes])
              Padding(padding: const EdgeInsets.all(8), child: Text(note)),
            if (output != null) ...[
              const Divider(),
              const ListTile(title: Text('Requested changes')),
              for (final e
                  in (output.metadataPatch?.values ??
                          <String, Object>{
                            'make': output.patch.make,
                            'model': output.patch.model,
                            if (output.patch.lens != null)
                              'lensModel': output.patch.lens!,
                          })
                      .entries)
                ListTile(
                  dense: true,
                  title: Text('Requested · ${e.key}'),
                  subtitle: SelectableText(e.value.toString()),
                ),
              for (final key in output.metadataPatch?.removals ?? <String>{})
                ListTile(dense: true, title: Text('Removed · $key')),
              const ListTile(title: Text('Processed metadata read back')),
              for (final e in output.inspection.metadata.entries)
                ListTile(
                  dense: true,
                  title: Text('Read back · ${e.key}'),
                  subtitle: SelectableText(e.value),
                ),
              for (final e in output.inspection.structure.entries)
                ListTile(
                  dense: true,
                  title: Text('Processed structure · ${e.key}'),
                  subtitle: SelectableText(e.value),
                ),
              for (final check in output.integrity.checks)
                ListTile(
                  dense: true,
                  title: Text('${check.name}: ${check.status}'),
                  subtitle: Text(check.detail),
                ),
              for (final limitation in output.integrity.limitations)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(limitation),
                ),
              TextButton(
                onPressed: controller.busy ? null : controller.verifyOriginal,
                child: const Text('Verify downloaded iCloud original'),
              ),
            ],
            if (profile != null && camera != null) ...[
              const ListTile(title: Text('Camera profile evidence')),
              for (final e in camera!.evidence.entries)
                ListTile(
                  dense: true,
                  title: Text(e.key),
                  subtitle: Text(e.value),
                ),
              for (final url in profile!.sources)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(url),
                ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _presets(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FutureBuilder<List<CameraProfile>>(
        future: catalog,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text(
              'Camera catalog unavailable. Manual editing and saved presets remain available.',
            );
          }
          final profiles = snapshot.data;
          if (profiles == null) return const LinearProgressIndicator();
          final brands = profiles.map((p) => p.brand).toSet().toList()..sort();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                menuMaxHeight: 220,
                itemHeight: 48.0,
                dropdownColor: const Color(0xFF162032),
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: Color(0xFF9CB5FF)),
                alignment: AlignmentDirectional.centerStart,
                key: const Key('profileBrand'),
                initialValue: brand,
                decoration: const InputDecoration(
                  labelText: 'Brand',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                items: brands.map((b) {
                  final isSelected = brand == b;
                  return DropdownMenuItem<String>(
                    value: b,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            b,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                              color: isSelected ? const Color(0xFF9CB5FF) : Colors.white,
                            ),
                          ),
                        ),
                        if (isSelected)
                          const Icon(Icons.check, size: 16, color: Color(0xFF9CB5FF)),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        brand = value;
                        profile = null;
                        camera = null;
                        _appliedFeedback = false;
                      }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                isExpanded: true,
                menuMaxHeight: 240,
                itemHeight: 48.0,
                dropdownColor: const Color(0xFF162032),
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: Color(0xFF9CB5FF)),
                alignment: AlignmentDirectional.centerStart,
                key: ValueKey('model-${brand ?? "none"}${profile != null ? "-${profile!.id}" : ""}'),
                initialValue: profile?.id,
                decoration: InputDecoration(
                  labelText: 'Model',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  suffixIcon: brand == null
                      ? null
                      : IconButton(
                          tooltip: 'Search models',
                          icon: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF9CB5FF)),
                          onPressed: widget.controller.busy
                              ? null
                              : () => _openModelSearchSheet(
                                    context,
                                    profiles.where((p) => p.brand == brand).toList(),
                                  ),
                        ),
                ),
                items: profiles
                    .where((p) => p.brand == brand)
                    .map(
                      (p) {
                        final isSelected = profile?.id == p.id;
                        return DropdownMenuItem<String>(
                          value: p.id,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  p.model,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                    color: isSelected ? const Color(0xFF9CB5FF) : Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check, size: 16, color: Color(0xFF9CB5FF)),
                            ],
                          ),
                        );
                      },
                    )
                    .toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        profile = profiles.firstWhere((p) => p.id == value);
                        camera = profile!.cameras.first;
                        _appliedFeedback = false;
                        _apply(
                          _profilePatch(widget.session),
                          notify: false,
                          fromProfile: true,
                        );
                      }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                isExpanded: true,
                menuMaxHeight: 200,
                itemHeight: 48.0,
                dropdownColor: const Color(0xFF162032),
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: Color(0xFF9CB5FF)),
                alignment: AlignmentDirectional.centerStart,
                key: ValueKey('camera-${profile?.id ?? "none"}${camera != null ? "-${camera!.id}" : ""}'),
                initialValue: camera?.id,
                decoration: const InputDecoration(
                  labelText: 'Camera',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                items: (profile?.cameras ?? <ProfileCamera>[])
                    .map(
                      (c) {
                        final isSelected = camera?.id == c.id;
                        return DropdownMenuItem<String>(
                          value: c.id,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  c.name,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                    color: isSelected ? const Color(0xFF9CB5FF) : Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check, size: 16, color: Color(0xFF9CB5FF)),
                            ],
                          ),
                        );
                      },
                    )
                    .toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        camera = profile!.cameras.firstWhere(
                          (c) => c.id == value,
                        );
                        _appliedFeedback = false;
                        _apply(
                          _profilePatch(widget.session),
                          notify: false,
                          fromProfile: true,
                        );
                      }),
              ),
              const SizedBox(height: 10),
              FilledButton(
                key: const Key('applyProfile'),
                style: FilledButton.styleFrom(
                  backgroundColor: _appliedFeedback
                      ? const Color(0xFF233658)
                      : const Color(0xFF243044),
                  foregroundColor: _appliedFeedback
                      ? const Color(0xFF9CB5FF)
                      : const Color(0xFFDCE6F8),
                ),
                onPressed:
                    profile == null || camera == null || widget.controller.busy
                    ? null
                    : () {
                        try {
                          _apply(
                            _profilePatch(widget.session),
                            fromProfile: true,
                          );
                          _appliedTimer?.cancel();
                          setState(() {
                            _appliedFeedback = true;
                            formError = null;
                          });
                          _appliedTimer = Timer(const Duration(seconds: 2), () {
                            if (mounted) {
                              setState(() => _appliedFeedback = false);
                            }
                          });
                        } catch (e) {
                          _appliedTimer?.cancel();
                          setState(() {
                            _appliedFeedback = false;
                            formError = e is FormatException ? e.message : e.toString();
                          });
                        }
                      },
                child: _appliedFeedback
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Applied', style: TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      )
                    : const Text('Apply & randomize'),
              ),
              if (_appliedFeedback) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF132720),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF224436)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 16, color: Color(0xFF84E4C7)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Settings applied. Press "Process" below to generate your file.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF84E4C7), fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              _automaticDates(),
              TextButton(
                onPressed: widget.controller.busy
                    ? null
                    : _configureRandomization,
                child: const Text('Randomization settings'),
              ),
              if (camera?.evidence.values.contains('descriptive-label') ??
                  false)
                const Text(
                  'Lens label is descriptive; exact capture wording has not been verified.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              Text(
                '${profiles.length} researched models. Unknown hardware fields are cleared rather than invented.',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 20),
      const Text('Saved presets'),
      for (final preset in widget.controller.presets)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(preset.name),
          onTap: widget.controller.busy ? null : () => _loadPreset(preset),
          subtitle: Text(
            preset.recipe == null
                ? 'Fixed metadata values'
                : 'Camera & randomization recipe',
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') {
                widget.controller.exportPreset(preset);
              } else {
                widget.controller.deletePreset(preset);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export preset')),
              PopupMenuItem(value: 'delete', child: Text('Delete preset')),
            ],
          ),
        ),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: widget.controller.busy ? null : _savePreset,
            child: const Text('Save current edits'),
          ),
          TextButton(
            onPressed: widget.controller.busy
                ? null
                : widget.controller.importPreset,
            child: const Text('Import preset'),
          ),
        ],
      ),
    ],
  );
  Widget _manual(BuildContext context) {
    final groups = metadataFields
        .where((f) => supported.contains(f.key))
        .map((f) => f.group)
        .toSet();
    return Column(
      children: [
        const Text(
          'Keep retains the original. Set changes a value. Remove deletes the selected field.',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        for (final group in groups)
          ExpansionTile(
            initiallyExpanded: group == 'Camera',
            title: Text(group),
            children: [
              if (group == 'Dates' || group == 'Video dates') _automaticDates(),
              for (final field in metadataFields.where(
                (f) => f.group == group && supported.contains(f.key),
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(field.label)),
                          DropdownButton<String>(
                            key: Key('${field.key}Mode'),
                            value: modes[field.key],
                            items: const [
                              DropdownMenuItem(
                                value: 'keep',
                                child: Text('Keep'),
                              ),
                              DropdownMenuItem(
                                value: 'set',
                                child: Text('Set'),
                              ),
                              DropdownMenuItem(
                                value: 'remove',
                                child: Text('Remove'),
                              ),
                            ],
                            onChanged: widget.controller.busy
                                ? null
                                : (mode) => setState(() {
                                    modes[field.key] = mode!;
                                    explicitOverrides.add(field.key);
                                  }),
                          ),
                        ],
                      ),
                      if (modes[field.key] == 'set')
                        TextField(
                          key: Key(
                            field.key == 'lensModel' ? 'lens' : field.key,
                          ),
                          controller: inputs[field.key],
                          onChanged: (_) => explicitOverrides.add(field.key),
                          enabled: !widget.controller.busy,
                          decoration: InputDecoration(
                            labelText: field.label,
                            hintText:
                                field.group == 'Dates' &&
                                    !field.key.startsWith('offset')
                                ? (widget.session.inspection.kind.isImage
                                      ? 'YYYY:MM:DD HH:mm:ss'
                                      : 'YYYY-MM-DDTHH:mm:ssZ')
                                : null,
                          ),
                          keyboardType: field.numeric
                              ? const TextInputType.numberWithOptions(
                                  signed: true,
                                  decimal: true,
                                )
                              : TextInputType.text,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        if (groups.isEmpty)
          const Text(
            'This format currently has no supported metadata operations.',
          ),
      ],
    );
  }

  Future<void> _loadPreset(SavedPreset preset) async {
    try {
      if (preset.recipe == null) {
        setState(() {
          profile = null;
          camera = null;
          brand = null;
        });
        _apply(
          widget.batch
              ? preset.patch
              : datesForMedia(
                  preset.patch,
                  image: widget.session.inspection.kind.isImage,
                  keptOffsets: widget.session.inspection.metadata,
                ),
        );
        return;
      }
      final profiles = await catalog;
      final recipe = preset.recipe!;
      final match = profiles.where((p) => p.id == recipe.profileId);
      if (match.isEmpty) {
        throw const FormatException(
          'This preset refers to an unavailable phone profile.',
        );
      }
      final model = match.single;
      final cameras = model.cameras.where((c) => c.id == recipe.cameraId);
      if (cameras.isEmpty) {
        throw const FormatException(
          'This preset refers to an unavailable camera.',
        );
      }
      if (!mounted) return;
      profile = model;
      camera = cameras.single;
      brand = model.brand;
      settings = recipe.settings;
      final generated = _profilePatch(widget.session);
      final values = {...generated.values};
      final removals = {...generated.removals};
      final overrides = widget.batch
          ? recipe.overrides
          : recipe.overrides == null
          ? null
          : datesForMedia(
              recipe.overrides!,
              image: widget.session.inspection.kind.isImage,
              keptOffsets: widget.session.inspection.metadata,
              keepFields: recipe.keepFields,
            );
      for (final key in recipe.keepFields) {
        values.remove(key);
        removals.remove(key);
      }
      for (final e
          in overrides?.values.entries ?? <MapEntry<String, Object>>[]) {
        values[e.key] = e.value;
        removals.remove(e.key);
      }
      for (final key in overrides?.removals ?? <String>{}) {
        values.remove(key);
        removals.add(key);
      }
      _apply(
        MetadataPatch(values: values, removals: removals),
        fromProfile: true,
      );
      profileBaseline = generated;
      explicitOverrides.addAll(overrides?.values.keys ?? <String>[]);
      explicitOverrides.addAll(overrides?.removals ?? <String>{});
      explicitOverrides.addAll(recipe.keepFields);
    } on FormatException catch (e) {
      if (mounted) setState(() => formError = e.message);
    }
  }

  ProfileRecipe? _currentRecipe(MetadataPatch patch) {
    final baseline = profileBaseline;
    if (profile == null || camera == null || baseline == null) return null;
    final overrides = <String, Object>{};
    final removed = <String>{};
    final keep = <String>{};
    for (final e in patch.values.entries) {
      if (baseline.values[e.key] != e.value ||
          explicitOverrides.contains(e.key)) {
        overrides[e.key] = e.value;
      }
    }
    for (final key in patch.removals) {
      if (!baseline.removals.contains(key)) removed.add(key);
    }
    for (final key in {...baseline.values.keys, ...baseline.removals}) {
      if (!patch.values.containsKey(key) && !patch.removals.contains(key)) {
        keep.add(key);
      }
    }
    return ProfileRecipe(
      profile!.id,
      camera!.id,
      settings,
      overrides: overrides.isEmpty && removed.isEmpty
          ? null
          : MetadataPatch(values: overrides, removals: removed),
      keepFields: keep,
    );
  }

  Future<void> _savePreset() async {
    try {
      final patch = _patch();
      final text = TextEditingController();
      var saveRecipe = profileBaseline != null;
      final name = await _ownedControllerDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Save preset'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                if (profileBaseline != null)
                  CheckboxListTile(
                    value: saveRecipe,
                    onChanged: (value) =>
                        update(() => saveRecipe = value ?? false),
                    title: const Text('Save camera & randomization recipe'),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, text.text),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
      text.dispose();
      if (name != null) {
        await widget.controller.savePreset(
          name,
          patch,
          recipe: saveRecipe ? _currentRecipe(patch) : null,
        );
      }
    } on FormatException catch (e) {
      setState(() => formError = e.message);
    }
  }

  Future<void> _configureRandomization() async {
    final isoMin = TextEditingController(text: settings.isoMin.toString()),
        isoMax = TextEditingController(text: settings.isoMax.toString()),
        days = TextEditingController(text: settings.pastDays.toString()),
        shutters = TextEditingController(
          text: settings.shutters.map((s) => s.toString()).join(', '),
        ),
        lat = TextEditingController(text: settings.latitude?.toString() ?? ''),
        lon = TextEditingController(text: settings.longitude?.toString() ?? ''),
        alt = TextEditingController(text: settings.altitude?.toString() ?? ''),
        radius = TextEditingController(
          text: settings.locationRadiusMeters.toString(),
        );
    var exposure = settings.randomizeExposure,
        dates = settings.randomizeDates,
        software = settings.randomizeSoftware;
    String? dialogError;
    final result = await _ownedControllerDialog<RandomizationSettings>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Randomization'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('Randomize ISO and shutter'),
                    value: exposure,
                    onChanged: (v) => update(() => exposure = v),
                  ),
                  for (final e in [
                    (isoMin, 'Minimum ISO'),
                    (isoMax, 'Maximum ISO'),
                    (shutters, 'Shutter seconds / fractions, comma separated'),
                  ])
                    TextField(
                      controller: e.$1,
                      decoration: InputDecoration(labelText: e.$2),
                    ),
                  SwitchListTile(
                    title: const Text('Randomize dates'),
                    value: dates,
                    onChanged: (v) => update(() => dates = v),
                  ),
                  TextField(
                    controller: days,
                    decoration: const InputDecoration(
                      labelText: 'Within the past days',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Randomize software when catalogued'),
                    value: software,
                    onChanged: (v) => update(() => software = v),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Optional location anchor. Leave both coordinates blank to preserve location.',
                    ),
                  ),
                  for (final e in [
                    (lat, 'Latitude'),
                    (lon, 'Longitude'),
                    (alt, 'Altitude (optional)'),
                    (radius, 'Radius (meters)'),
                  ])
                    TextField(
                      controller: e.$1,
                      decoration: InputDecoration(labelText: e.$2),
                    ),
                  if (dialogError != null)
                    Text(
                      dialogError!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                try {
                  final shutterField = metadataFields.firstWhere(
                    (f) => f.key == 'exposureTime',
                  );
                  final next = RandomizationSettings(
                    isoMin: int.parse(isoMin.text),
                    isoMax: int.parse(isoMax.text),
                    pastDays: int.parse(days.text),
                    shutters: shutters.text
                        .split(',')
                        .map(
                          (v) =>
                              (MetadataPatch.parseField(shutterField, v) as num)
                                  .toDouble(),
                        )
                        .toList(),
                    randomizeExposure: exposure,
                    randomizeDates: dates,
                    randomizeSoftware: software,
                    latitude: lat.text.trim().isEmpty
                        ? null
                        : double.parse(lat.text),
                    longitude: lon.text.trim().isEmpty
                        ? null
                        : double.parse(lon.text),
                    altitude: alt.text.trim().isEmpty
                        ? null
                        : double.parse(alt.text),
                    locationRadiusMeters: double.parse(radius.text),
                  );
                  final invalid = next.validate();
                  if (invalid != null) {
                    throw FormatException(invalid);
                  }
                  Navigator.pop(context, next);
                } on FormatException catch (e) {
                  update(() => dialogError = e.message);
                }
              },
              child: const Text('Use settings'),
            ),
          ],
        ),
      ),
    );
    for (final c in [isoMin, isoMax, days, shutters, lat, lon, alt, radius]) {
      c.dispose();
    }
    if (result != null && mounted) {
      _settingsChanged(result);
    }
  }
}

class _ModelSearchSheet extends StatefulWidget {
  const _ModelSearchSheet({
    required this.availableProfiles,
    required this.selectedProfileId,
  });

  final List<CameraProfile> availableProfiles;
  final String? selectedProfileId;

  @override
  State<_ModelSearchSheet> createState() => _ModelSearchSheetState();
}

class _ModelSearchSheetState extends State<_ModelSearchSheet> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = widget.availableProfiles.where((p) {
      if (query.isEmpty) return true;
      return p.model.toLowerCase().contains(query) ||
          p.brand.toLowerCase().contains(query);
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(
              children: [
                Text(
                  'Select Camera Model',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: 'Search models…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No matching models found.',
                        style: TextStyle(color: Colors.white60),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: filtered.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final p = filtered[index];
                        final isSelected = widget.selectedProfileId == p.id;
                        return ListTile(
                          dense: true,
                          title: Text(
                            p.model,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? const Color(0xFF9CB5FF)
                                  : Colors.white,
                            ),
                          ),
                          subtitle: Text(
                            '${p.brand} · ${p.cameras.length} camera(s)',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white60,
                            ),
                          ),
                          trailing: isSelected
                              ? const Icon(
                                  Icons.check,
                                  color: Color(0xFF9CB5FF),
                                  size: 20,
                                )
                              : null,
                          onTap: () {
                            Navigator.of(context).pop(p);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

