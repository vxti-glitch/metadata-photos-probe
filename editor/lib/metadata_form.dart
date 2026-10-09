import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_profiles.dart';
import 'editor_controller.dart';
import 'media_models.dart';
import 'metadata_patch.dart';
import 'metadata_dates.dart';

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

class _MetadataFormState extends State<MetadataForm> {
  final inputs = <String, TextEditingController>{};
  final modes = <String, String>{};
  final random = Random.secure();
  late final Future<List<CameraProfile>> catalog;
  CameraProfile? profile;
  ProfileCamera? camera;
  String? brand;
  RandomizationSettings settings = const RandomizationSettings();
  String? formError;
  MetadataPatch? profileBaseline;
  final explicitOverrides = <String>{};
  @override
  void initState() {
    super.initState();
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

  MetadataPatch _patch() {
    final values = <String, Object>{};
    final removed = <String>[];
    for (final f in metadataFields) {
      if (!supported.contains(f.key)) continue;
      if (modes[f.key] == 'remove') {
        removed.add(f.key);
      } else if (modes[f.key] == 'set') {
        values[f.key] = MetadataPatch.parseField(f, inputs[f.key]!.text);
      }
    }
    final result = MetadataPatch(values: values, removals: removed);
    final invalid = result.validate();
    if (invalid != null) throw FormatException(invalid);
    return result;
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
        final manual = _patch();
        final patches = <String, MetadataPatch>{};
        for (final source in sources) {
          if (profile != null && camera != null && profileBaseline != null) {
            final generated = _profilePatch(source);
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
                  (profileBaseline!.values.containsKey(key) ||
                      profileBaseline!.removals.contains(key))) {
                values.remove(key);
                removals.remove(key);
              } else if (intent == 'set' &&
                  manual.values[key] != profileBaseline!.values[key]) {
                values[key] = manual.values[key]!;
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
            patches[source.id] = manual;
          }
        }
        await widget.controller.processBatch(patches);
      } else {
        await widget.controller.processMetadata(_patch());
      }
      if (mounted) setState(() => formError = null);
    } on FormatException catch (e) {
      setState(() => formError = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final source = widget.session;
    final output = source.processing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.batch
              ? 'Edit ${controller.batchSelection.length} files'
              : source.displayName,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${source.inspection.kind.label} · ${source.inspection.sizeLabel}',
          style: const TextStyle(color: Colors.white60),
        ),
        if (formError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              formError!,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        const SizedBox(height: 20),
        DefaultTabController(
          length: 2,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Presets'),
                  Tab(text: 'Edit'),
                ],
              ),
              SizedBox(
                height: 460,
                child: TabBarView(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 16),
                      child: _presets(context),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 16),
                      child: _manual(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('process'),
          onPressed: controller.busy ? null : _process,
          icon: const Icon(Icons.auto_fix_high_outlined),
          label: Text(widget.batch ? 'Process selected files' : 'Process'),
        ),
        if (!widget.batch && output != null) ...[
          const SizedBox(height: 20),
          Text(
            output.outputDisplayName ?? 'Processed copy ready',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (output.integrity.hasMismatch)
            const Text(
              'A preservation check failed. Export blocked.',
              style: TextStyle(color: Colors.redAccent),
            ),
          if (output.integrity.needsAcknowledgment &&
              !output.integrity.hasMismatch)
            CheckboxListTile(
              key: const Key('acknowledge'),
              contentPadding: EdgeInsets.zero,
              value: controller.acknowledged,
              onChanged: controller.busy
                  ? null
                  : (v) => controller.acknowledge(v ?? false),
              title: const Text('I accept the stated preservation limitations'),
              subtitle: Text(output.integrity.limitations.join('\n')),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('exportFiles'),
            onPressed: controller.canExport ? controller.exportFiles : null,
            icon: const Icon(Icons.ios_share),
            label: const Text('Export to Files'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('openICloud'),
            onPressed: controller.busy ? null : controller.openICloud,
            child: const Text('Open iCloud Photos'),
          ),
          const Text(
            'Upload the exported file in Safari, then let it sync to Photos.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
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
                key: const Key('profileBrand'),
                initialValue: brand,
                decoration: const InputDecoration(labelText: 'Brand'),
                items: brands
                    .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                    .toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        brand = value;
                        profile = null;
                        camera = null;
                      }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('model-${brand ?? "none"}'),
                initialValue: profile?.id,
                decoration: const InputDecoration(labelText: 'Model'),
                items: profiles
                    .where((p) => p.brand == brand)
                    .map(
                      (p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.model)),
                    )
                    .toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        profile = profiles.firstWhere((p) => p.id == value);
                        camera = profile!.cameras.first;
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
                key: ValueKey('camera-${profile?.id ?? "none"}'),
                initialValue: camera?.id,
                decoration: const InputDecoration(labelText: 'Camera'),
                items: (profile?.cameras ?? <ProfileCamera>[])
                    .map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    )
                    .toList(),
                onChanged: widget.controller.busy
                    ? null
                    : (value) => setState(() {
                        camera = profile!.cameras.firstWhere(
                          (c) => c.id == value,
                        );
                        _apply(
                          _profilePatch(widget.session),
                          notify: false,
                          fromProfile: true,
                        );
                      }),
              ),
              const SizedBox(height: 10),
              FilledButton.tonal(
                key: const Key('applyProfile'),
                onPressed:
                    profile == null || camera == null || widget.controller.busy
                    ? null
                    : () {
                        _apply(
                          _profilePatch(widget.session),
                          fromProfile: true,
                        );
                      },
                child: const Text('Apply & randomize'),
              ),
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
    if (preset.recipe == null) {
      setState(() {
        profile = null;
        camera = null;
        brand = null;
      });
      _apply(preset.patch);
      return;
    }
    try {
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
      for (final key in recipe.keepFields) {
        values.remove(key);
        removals.remove(key);
      }
      for (final e
          in recipe.overrides?.values.entries ?? <MapEntry<String, Object>>[]) {
        values[e.key] = e.value;
        removals.remove(e.key);
      }
      for (final key in recipe.overrides?.removals ?? <String>{}) {
        values.remove(key);
        removals.add(key);
      }
      _apply(
        MetadataPatch(values: values, removals: removals),
        fromProfile: true,
      );
      profileBaseline = generated;
      explicitOverrides.addAll(recipe.overrides?.values.keys ?? <String>[]);
      explicitOverrides.addAll(recipe.overrides?.removals ?? <String>{});
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
      final name = await showDialog<String>(
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
    final result = await showDialog<RandomizationSettings>(
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
                  if (invalid != null) throw FormatException(invalid);
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
    if (result != null && mounted) _settingsChanged(result);
  }
}
