import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_profiles.dart';
import 'editor_controller.dart';
import 'media_bridge.dart' show simplifyUserError;
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
  int _batchStaggerSeconds = 0;
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

    catalog = loadCameraProfiles().then((profiles) {
      if (mounted) _restoreSavedProfile(profiles);
      return profiles;
    });
  }

  Future<void> _restoreSavedProfile(List<CameraProfile> profiles) async {
    if (profile != null) return;
    final savedBrand = widget.controller.selectedBrand;
    final savedProfileId = widget.controller.selectedProfileId;
    final savedCameraId = widget.controller.selectedCameraId;

    if (savedBrand != null || savedProfileId != null) {
      CameraProfile? matchedProfile;
      if (savedProfileId != null) {
        matchedProfile = profiles
            .where((p) => p.id == savedProfileId)
            .firstOrNull;
      }
      ProfileCamera? matchedCamera;
      if (matchedProfile != null) {
        if (savedCameraId != null) {
          matchedCamera = matchedProfile.cameras
              .where((c) => c.id == savedCameraId)
              .firstOrNull;
        }
        matchedCamera ??= matchedProfile.cameras.firstOrNull;
      }

      if (mounted) {
        setState(() {
          brand = matchedProfile?.brand ?? savedBrand;
          profile = matchedProfile;
          camera = matchedCamera;
          if (widget.session.processing?.metadataPatch == null &&
              profile != null &&
              camera != null) {
            _apply(
              _profilePatch(widget.session),
              notify: false,
              fromProfile: true,
            );
          }
        });
      }
      return;
    }

    final host = await widget.controller.getHostDevice();
    if (!mounted || profile != null) return;
    if (host != null && host['profileId'] != null) {
      final hostProfile = profiles
          .where((p) => p.id == host['profileId'])
          .firstOrNull;
      if (hostProfile != null) {
        setState(() {
          brand = hostProfile.brand;
          profile = hostProfile;
          camera = hostProfile.cameras.firstOrNull;
        });
      }
    }
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
        if (fields.contains(entry.key)) entry.key: entry.value,
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
    final hasCompeting =
        source.inspection.structure['competingMetadata'] == 'true' ||
        source.inspection.notes.any(
          (n) =>
              n.contains('Additional XMP') ||
              n.contains('Additional PNG text') ||
              n.contains('competing'),
        );
    if (!hasCompeting) {
      final presentKeys = source.inspection.metadata.keys.toSet();
      // Unknown specifications must not become an incompatible mix of two phones.
      for (final key in [
        ...profile!.clearFields,
        ...camera!.clearFields,
        'software',
        'lensMake',
        'hostComputer',
      ]) {
        if (presentKeys.contains(key) &&
            fields.contains(key) &&
            !patch.values.containsKey(key)) {
          removals.add(key);
        }
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
      widget.controller.recordError(e.message);
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
      initialDate: initial.year >= 1900 && initial.year <= 2037
          ? initial
          : DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2038, 1, 1),
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
        final sources = widget.controller.sessions
            .where((s) => widget.controller.batchSelection.contains(s.id))
            .toList();
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
        for (var i = 0; i < sources.length; i++) {
          final source = sources[i];
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
          MetadataPatch itemPatch;
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
            itemPatch = MetadataPatch(values: values, removals: removals);
          } else {
            itemPatch = _standaloneAutomaticDates(itemManual, source);
          }
          patches[source.id] = itemPatch;
        }
        final staggeredPatches = offsetBatchDatePatches(
          patches,
          Duration(seconds: _batchStaggerSeconds),
        );
        final sanitizedPatches = <String, MetadataPatch>{};
        for (final entry in staggeredPatches.entries) {
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
      widget.controller.recordError(e.message);
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
      backgroundColor: const Color(0xFF121214),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
        _apply(_profilePatch(widget.session), notify: false, fromProfile: true);
      });
      widget.controller.rememberSelectedProfile(
        brand: selected.brand,
        profileId: selected.id,
        cameraId: camera?.id,
      );
    }
  }

  Future<void> _openBrandPickerSheet(
    BuildContext context,
    List<String> brands, {
    List<CameraProfile>? profiles,
  }) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121214),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _BrandPickerSheet(
        brands: brands,
        selectedBrand: brand,
        profiles: profiles,
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        brand = selected;
        profile = null;
        camera = null;
        profileBaseline = null;
        _appliedFeedback = false;
      });
      widget.controller.rememberSelectedProfile(
        brand: selected,
        profileId: null,
        cameraId: null,
      );
    }
  }

  Future<void> _openCameraPickerSheet(
    BuildContext context,
    List<ProfileCamera> cameras,
  ) async {
    final selected = await showModalBottomSheet<ProfileCamera>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121214),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _CameraPickerSheet(
        cameras: cameras,
        selectedCameraId: camera?.id,
        profileModel: profile?.model,
      ),
    );
    if (selected != null && mounted && selected.id != camera?.id) {
      setState(() {
        camera = selected;
        _appliedFeedback = false;
        _apply(_profilePatch(widget.session), notify: false, fromProfile: true);
      });
      widget.controller.rememberSelectedProfile(
        brand: brand ?? profile?.brand,
        profileId: profile?.id,
        cameraId: selected.id,
      );
    }
  }

  Widget _buildSelectorField({
    required Key key,
    required String label,
    required String value,
    required bool enabled,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    // Dropdowns must use compact 48px height (itemHeight: 48.0)
    final isPlaceholder =
        !enabled || value.startsWith('Select') || value.startsWith('Choose');
    return Container(
      constraints: const BoxConstraints(minHeight: 52.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: key,
          onTap: enabled && !widget.controller.busy ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: enabled
                              ? (isPlaceholder ? Colors.white38 : Colors.white)
                              : Colors.white24,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: enabled ? const Color(0xFF0A84FF) : Colors.white24,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingResults(BuildContext context, Processing output) {
    final controller = widget.controller;
    final isMismatch = output.integrity.hasMismatch;
    final needsAck = output.integrity.needsAcknowledgment && !isMismatch;
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isMismatch ? const Color(0xFF2C1518) : const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMismatch ? const Color(0xFF5A2026) : const Color(0xFF2C2C2E),
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
                color: isMismatch ? Colors.redAccent : const Color(0xFF0A84FF),
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
                    color: isMismatch ? Colors.redAccent : Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF121214),
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
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  output.outputDisplayName ?? 'Processed copy',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Color(0xFF2C2C2E)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      output.autoExportFolder == null
                          ? Icons.phone_iphone_outlined
                          : Icons.folder_outlined,
                      size: 16,
                      color: const Color(0xFF0A84FF),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        output.autoExportFolder == null
                            ? 'Held in the app. Export to Files after reviewing the checks.'
                            : 'Saved to: ${output.autoExportFolder}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _buildMetadataDiffCard(context, widget.session, output),
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
                  onPressed: controller.canExport
                      ? controller.exportFiles
                      : null,
                  icon: const Icon(Icons.folder_shared_outlined, size: 18),
                  label: const Text('Export to Files'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('shareFiles'),
                  onPressed: controller.canExport
                      ? controller.shareFiles
                      : null,
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Share / Save to Photos'),
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
            style: const TextStyle(
              color: Color(0xFF0A84FF),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2C2C2E)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome_motion_outlined,
                  color: Color(0xFF0A84FF),
                  size: 20,
                ),
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
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2C2C2E)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.schedule_rounded,
                  color: Color(0xFF0A84FF),
                  size: 18,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Timestamp Spacing',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                DropdownButton<int>(
                  key: const Key('batchTimestampStagger'),
                  value: _batchStaggerSeconds,
                  dropdownColor: const Color(0xFF1C1C1E),
                  underline: const SizedBox(),
                  style: const TextStyle(
                    color: Color(0xFF0A84FF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Simultaneous')),
                    DropdownMenuItem(value: 1, child: Text('+1s stagger')),
                    DropdownMenuItem(value: 5, child: Text('+5s stagger')),
                    DropdownMenuItem(value: 10, child: Text('+10s stagger')),
                    DropdownMenuItem(value: 30, child: Text('+30s stagger')),
                    DropdownMenuItem(value: 60, child: Text('+1m stagger')),
                  ],
                  onChanged: controller.busy
                      ? null
                      : (val) =>
                            setState(() => _batchStaggerSeconds = val ?? 0),
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
          const SizedBox(height: 12),
          _buildMediaInspectorHUD(context, source),
        ],
        if (formError != null)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF261215),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF591C22)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFFF453A),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Attention Needed',
                        style: TextStyle(
                          color: Color(0xFFFF453A),
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        simplifyUserError(formError!),
                        style: const TextStyle(
                          color: Color(0xFFFFB4AB),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Color(0xFFFFB4AB),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  tooltip: 'Dismiss',
                  onPressed: () => setState(() => formError = null),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        TabBar(
          controller: _tabController,
          onTap: (index) {
            if (_tabIndex != index) {
              setState(() => _tabIndex = index);
            }
          },
          indicatorColor: const Color(0xFF0A84FF),
          labelColor: const Color(0xFF0A84FF),
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
          label: Text(
            widget.batch
                ? 'Process ${controller.batchSelection.length} selected files'
                : 'Process file',
          ),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Device Profile',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8E8E93),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('matchDeviceButton'),
                    style: TextButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      foregroundColor: const Color(0xFF0A84FF),
                    ),
                    onPressed: widget.controller.busy
                        ? null
                        : () async {
                            final host = await widget.controller
                                .getHostDevice();
                            if (!mounted) return;
                            if (host != null && host['profileId'] != null) {
                              final matched = profiles
                                  .where((p) => p.id == host['profileId'])
                                  .firstOrNull;
                              if (matched != null) {
                                setState(() {
                                  brand = matched.brand;
                                  profile = matched;
                                  camera = matched.cameras.firstOrNull;
                                  profileBaseline = null;
                                  _appliedFeedback = false;
                                  if (camera != null) {
                                    _apply(
                                      _profilePatch(widget.session),
                                      fromProfile: true,
                                    );
                                  }
                                });
                                widget.controller.rememberSelectedProfile(
                                  brand: matched.brand,
                                  profileId: matched.id,
                                  cameraId: camera?.id,
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.phone_iphone_rounded, size: 15),
                    label: const Text(
                      'Match iPhone',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _buildSelectorField(
                key: const Key('profileBrand'),
                label: 'Brand',
                value: brand ?? 'Select brand',
                enabled: true,
                onTap: () =>
                    _openBrandPickerSheet(context, brands, profiles: profiles),
              ),
              const SizedBox(height: 8),
              _buildSelectorField(
                key: ValueKey('model-${brand ?? "none"}'),
                label: 'Model',
                value:
                    profile?.model ??
                    (brand == null ? 'Choose a brand first' : 'Select model'),
                enabled: brand != null,
                onTap: brand == null
                    ? null
                    : () => _openModelSearchSheet(
                        context,
                        profiles.where((p) => p.brand == brand).toList(),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (brand != null)
                      IconButton(
                        key: const Key('searchModels'),
                        tooltip: 'Search models',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        visualDensity: VisualDensity.compact,
                        splashRadius: 16,
                        icon: const Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: Color(0xFF0A84FF),
                        ),
                        onPressed: widget.controller.busy
                            ? null
                            : () => _openModelSearchSheet(
                                context,
                                profiles
                                    .where((p) => p.brand == brand)
                                    .toList(),
                              ),
                      ),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: brand != null
                          ? const Color(0xFF0A84FF)
                          : Colors.white24,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _buildSelectorField(
                key: ValueKey(
                  'camera-${profile?.id ?? "none"}${camera != null ? "-${camera!.id}" : ""}',
                ),
                label: 'Camera',
                value:
                    camera?.name ??
                    (profile == null
                        ? 'Choose a model first'
                        : 'Select camera'),
                enabled: profile != null,
                onTap: profile == null
                    ? null
                    : () => _openCameraPickerSheet(context, profile!.cameras),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('applyProfile'),
                style: FilledButton.styleFrom(
                  backgroundColor: _appliedFeedback
                      ? const Color(0xFF2C2C2E)
                      : const Color(0xFF1C1C1E),
                  foregroundColor: _appliedFeedback
                      ? const Color(0xFF0A84FF)
                      : Colors.white,
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
                          final err = e is FormatException
                              ? e.message
                              : e.toString();
                          widget.controller.recordError(err);
                          setState(() {
                            _appliedFeedback = false;
                            formError = err;
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
                          Text(
                            'Applied',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      )
                    : const Text('Apply & randomize'),
              ),
              if (_appliedFeedback) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF132720),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF224436)),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        size: 16,
                        color: Color(0xFF84E4C7),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Settings applied. Press "Process" below to generate your file.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF84E4C7),
                            fontWeight: FontWeight.w500,
                          ),
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
      const SizedBox(height: 10),
      if (widget.controller.presets.isEmpty)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF2C2C2E)),
          ),
          child: const Center(
            child: Text(
              'No saved presets. Save current edits or import a recipe.',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
            ),
          ),
        )
      else
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2C2C2E)),
          ),
          child: Material(
            color: const Color(0xFF1C1C1E),
            child: Column(
              children: [
                for (var i = 0; i < widget.controller.presets.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFF2C2C2E),
                      indent: 52,
                    ),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 2,
                    ),
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: widget.controller.presets[i].recipe == null
                            ? const Color(0xFF2C2C2E)
                            : const Color(0xFF1E2A3E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        widget.controller.presets[i].recipe == null
                            ? Icons.tune_rounded
                            : Icons.auto_awesome_rounded,
                        size: 16,
                        color: widget.controller.presets[i].recipe == null
                            ? const Color(0xFF8E8E93)
                            : const Color(0xFF0A84FF),
                      ),
                    ),
                    title: Text(
                      widget.controller.presets[i].name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      widget.controller.presets[i].recipe == null
                          ? 'Fixed metadata values'
                          : 'Camera & randomization recipe',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8E8E93),
                      ),
                    ),
                    onTap: widget.controller.busy
                        ? null
                        : () => _loadPreset(widget.controller.presets[i]),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'export') {
                          widget.controller.exportPreset(
                            widget.controller.presets[i],
                          );
                        } else {
                          widget.controller.deletePreset(
                            widget.controller.presets[i],
                          );
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'export',
                          child: Text('Export preset'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete preset'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: widget.controller.busy ? null : _savePreset,
            icon: const Icon(Icons.bookmark_add_outlined, size: 16),
            label: const Text('Save current edits'),
          ),
          OutlinedButton.icon(
            onPressed: widget.controller.busy
                ? null
                : widget.controller.importPreset,
            icon: const Icon(Icons.file_download_outlined, size: 16),
            label: const Text('Import preset'),
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
              if (group == 'Location')
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    key: const Key('pickLocationMap'),
                    onPressed: widget.controller.busy
                        ? null
                        : _selectLocationOnMap,
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('Select Location on Map'),
                  ),
                ),
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
                      if (modes[field.key] == 'set') ...[
                        const SizedBox(height: 6),
                        Semantics(
                          label: field.label,
                          child: TextField(
                            key: Key(
                              field.key == 'lensModel' ? 'lens' : field.key,
                            ),
                            controller: inputs[field.key],
                            onChanged: (_) => explicitOverrides.add(field.key),
                            enabled: !widget.controller.busy,
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
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
                        ),
                      ],
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
        widget.controller.rememberSelectedProfile(
          brand: null,
          profileId: null,
          cameraId: null,
        );
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
      widget.controller.rememberSelectedProfile(
        brand: model.brand,
        profileId: model.id,
        cameraId: cameras.single.id,
      );
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
      widget.controller.recordError(e.message);
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
                  onChanged: (_) => update(() {}),
                  decoration: InputDecoration(
                    labelText: 'Name',
                    helperText: 'Up to 128 UTF-8 bytes',
                    errorText: text.text.isEmpty
                        ? null
                        : validatePresetName(text.text),
                  ),
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
                onPressed: validatePresetName(text.text) == null
                    ? () => Navigator.pop(context, text.text)
                    : null,
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
      widget.controller.recordError(e.message);
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

  Future<void> _selectLocationOnMap() async {
    final currentLat = double.tryParse(inputs['latitude']?.text ?? '');
    final currentLon = double.tryParse(inputs['longitude']?.text ?? '');
    final loc = await widget.controller.pickLocation(
      latitude: currentLat,
      longitude: currentLon,
    );
    if (loc != null && mounted) {
      setState(() {
        inputs['latitude']?.text = loc['latitude']!.toStringAsFixed(6);
        inputs['longitude']?.text = loc['longitude']!.toStringAsFixed(6);
        modes['latitude'] = 'set';
        modes['longitude'] = 'set';
        explicitOverrides.add('latitude');
        explicitOverrides.add('longitude');
      });
    }
  }

  Widget _buildMediaInspectorHUD(BuildContext context, MediaSession source) {
    final meta = source.inspection.metadata;
    final make = meta['make'];
    final model = meta['model'];
    final parts = <String>[];
    if (make != null && make != 'Apple') parts.add(make);
    if (model != null) parts.add(model);
    final cameraName = parts.join(' ');
    final lens = meta['lensModel'] ?? meta['lens'];
    final fNumber = meta['fNumber'];
    final shutter = meta['exposureTime'];
    final iso = meta['iso'];
    final focal = meta['focalLength35mm'] ?? meta['focalLength'];
    final hasGps =
        meta.containsKey('latitude') && meta.containsKey('longitude');
    final dimensions =
        source.details['Dimensions'] ??
        source.inspection.structure['resolution'] ??
        (meta['pixelWidth'] != null && meta['pixelHeight'] != null
            ? '${meta['pixelWidth']}×${meta['pixelHeight']}'
            : null);

    return Container(
      key: const Key('mediaInspectorHUD'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                source.inspection.kind.isImage
                    ? Icons.camera_alt_outlined
                    : Icons.videocam_outlined,
                color: const Color(0xFF0A84FF),
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cameraName.isNotEmpty
                      ? cameraName
                      : 'Original Hardware Unspecified',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              OutlinedButton.icon(
                key: const Key('quickPrivacyScrubButton'),
                onPressed: widget.controller.busy
                    ? null
                    : () => _openQuickPrivacyScrubber(context),
                icon: const Icon(Icons.shield_outlined, size: 14),
                label: const Text(
                  'Quick Scrub',
                  style: TextStyle(fontSize: 11),
                ),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  side: const BorderSide(color: Color(0xFF3A3A3C)),
                ),
              ),
            ],
          ),
          if (lens != null && lens.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              lens,
              style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildHUDChip(
                label: fNumber != null ? 'ƒ/$fNumber' : 'ƒ/--',
                active: fNumber != null,
              ),
              _buildHUDChip(
                label: shutter != null ? '${shutter}s' : '--s',
                active: shutter != null,
              ),
              _buildHUDChip(
                label: iso != null ? 'ISO $iso' : 'ISO --',
                active: iso != null,
              ),
              _buildHUDChip(
                label: focal != null ? '${focal}mm' : '--mm',
                active: focal != null,
              ),
              if (dimensions != null)
                _buildHUDChip(label: dimensions, active: true),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: hasGps
                      ? const Color(0xFF132720)
                      : const Color(0xFF121214),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: hasGps
                        ? const Color(0xFF224436)
                        : const Color(0xFF2C2C2E),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasGps ? Icons.location_on : Icons.location_off_outlined,
                      size: 12,
                      color: hasGps
                          ? const Color(0xFF84E4C7)
                          : const Color(0xFF8E8E93),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      hasGps ? 'GPS Tagged' : 'No Geotag',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: hasGps
                            ? const Color(0xFF84E4C7)
                            : const Color(0xFF8E8E93),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHUDChip({required String label, required bool active}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF121214),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: active ? Colors.white : const Color(0xFF8E8E93),
        ),
      ),
    );
  }

  Future<void> _openQuickPrivacyScrubber(BuildContext context) async {
    final scrubbed = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121214),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _QuickPrivacyScrubberSheet(supportedFields: supported),
    );
    if (scrubbed != null && scrubbed.isNotEmpty && mounted) {
      setState(() {
        for (final key in scrubbed) {
          modes[key] = 'remove';
          explicitOverrides.add(key);
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
          SnackBar(
            content: Text(
              'Privacy scrub queued for ${scrubbed.length} fields. Tap "Process file" to write cleaned media.',
            ),
            backgroundColor: const Color(0xFF1C1C1E),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildMetadataDiffCard(
    BuildContext context,
    MediaSession source,
    Processing output,
  ) {
    final original = source.inspection.metadata;
    final processed = output.inspection.metadata;
    final removals = output.metadataPatch?.removals ?? <String>[];

    final changed = <String, (String, String)>{};
    for (final entry in processed.entries) {
      final origVal = original[entry.key];
      if (origVal != null && origVal != entry.value) {
        changed[entry.key] = (origVal, entry.value);
      } else if (origVal == null &&
          (output.metadataPatch?.values.containsKey(entry.key) ?? false)) {
        changed[entry.key] = ('(none)', entry.value);
      }
    }

    final preserved = <String>[];
    for (final entry in processed.entries) {
      if (!changed.containsKey(entry.key) &&
          original[entry.key] == entry.value) {
        preserved.add(entry.key);
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C2C2E)),
      ),
      child: Material(
        color: const Color(0xFF121214),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('metadataDiffTile'),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.compare_arrows_rounded,
                  color: Color(0xFF0A84FF),
                  size: 18,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Metadata Diff (Before vs After)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${changed.length} changed · ${removals.length} removed · ${preserved.length} preserved',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(color: Color(0xFF2C2C2E), height: 1),
                    const SizedBox(height: 8),
                    if (changed.isNotEmpty) ...[
                      const Text(
                        'CHANGED / ADDED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFF0A84FF),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final entry in changed.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${entry.key}: ',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white70,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${entry.value.$1}  ➔  ${entry.value.$2}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: Color(0xFF84E4C7),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    if (removals.isNotEmpty) ...[
                      const Text(
                        'REMOVED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFFFF453A),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final key in removals)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.remove_circle_outline,
                                size: 12,
                                color: Color(0xFFFF453A),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                key,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFFFB4AB),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    if (preserved.isNotEmpty) ...[
                      Text(
                        'PRESERVED (${preserved.length} tags unchanged)',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preserved.join(', '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    final brandName = widget.availableProfiles.isNotEmpty
        ? widget.availableProfiles.first.brand
        : 'Camera';

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => SafeArea(
        top: false,
        child: Padding(
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
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3A3C),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Select Camera Model',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$brandName catalog · ${widget.availableProfiles.length} profiles',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF8E8E93),
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(22),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      child: Center(
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            color: Color(0xFF2C2C2E),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Color(0xFF8E8E93),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                height: 38,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF2C2C2E)),
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: false,
                  textAlignVertical: TextAlignVertical.center,
                  cursorColor: const Color(0xFF0A84FF),
                  cursorWidth: 1.5,
                  cursorHeight: 16,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search $brandName models…',
                    hintStyle: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF636366),
                    ),
                    filled: false,
                    fillColor: Colors.transparent,
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 38,
                    ),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(left: 10, right: 6),
                      child: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: Color(0xFF0A84FF),
                      ),
                    ),
                    isDense: true,
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.only(
                      left: 4,
                      right: 10,
                      top: 10,
                      bottom: 10,
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 38,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            icon: const Icon(
                              Icons.clear_rounded,
                              size: 16,
                              color: Color(0xFF8E8E93),
                            ),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2C2C2E)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: filtered.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search_off_rounded,
                                  size: 32,
                                  color: Color(0xFF636366),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'No matching models found.',
                                  style: TextStyle(
                                    color: Color(0xFF8E8E93),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: EdgeInsets.zero,
                          itemCount: filtered.length,
                          separatorBuilder: (context, index) => const Divider(
                            height: 1,
                            thickness: 1,
                            indent: 16,
                            endIndent: 16,
                            color: Color(0xFF2C2C2E),
                          ),
                          itemBuilder: (context, index) {
                            final p = filtered[index];
                            final isSelected = widget.selectedProfileId == p.id;
                            final cameraSummary = p.cameras.length == 1
                                ? '1 camera'
                                : '${p.cameras.length} cameras';
                            return InkWell(
                              onTap: () => Navigator.of(context).pop(p),
                              child: Container(
                                color: isSelected
                                    ? const Color(0xFF2C2C2E)
                                    : Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            p.model,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: isSelected
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              color: isSelected
                                                  ? const Color(0xFF0A84FF)
                                                  : Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${p.brand} · $cameraSummary',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF8E8E93),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isSelected)
                                      Container(
                                        width: 20,
                                        height: 20,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF0A84FF),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.check_rounded,
                                          size: 13,
                                          color: Color(0xFFFFFFFF),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandPickerSheet extends StatelessWidget {
  const _BrandPickerSheet({
    required this.brands,
    required this.selectedBrand,
    this.profiles,
  });

  final List<String> brands;
  final String? selectedBrand;
  final List<CameraProfile>? profiles;

  String _brandGlyph(String brand) {
    switch (brand.toLowerCase()) {
      case 'apple':
        return '';
      case 'google':
        return 'G';
      case 'samsung':
        return 'S';
      default:
        return brand.isNotEmpty ? brand.substring(0, 1).toUpperCase() : '?';
    }
  }

  String _brandSubtitle(String brand) {
    final count = profiles?.where((p) => p.brand == brand).length;
    if (brand.toLowerCase() == 'apple') {
      return count != null
          ? '$count researched iPhone models'
          : 'Apple iPhone models';
    } else if (brand.toLowerCase() == 'google') {
      return count != null
          ? '$count Pixel phone models'
          : 'Google Pixel models';
    } else if (brand.toLowerCase() == 'samsung') {
      return count != null
          ? '$count Galaxy S-series models'
          : 'Samsung Galaxy models';
    }
    return count != null ? '$count camera models' : '$brand models';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select Brand',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${brands.length} camera manufacturers available',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(22),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2C2C2E),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: brands.length,
                  separatorBuilder: (context, index) => const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 56,
                    endIndent: 16,
                    color: Color(0xFF2C2C2E),
                  ),
                  itemBuilder: (context, index) {
                    final b = brands[index];
                    final isSelected = selectedBrand == b;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(b),
                      child: Container(
                        color: isSelected
                            ? const Color(0xFF2C2C2E)
                            : Colors.transparent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2C2C2E),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _brandGlyph(b),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    b,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: isSelected
                                          ? const Color(0xFF0A84FF)
                                          : Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    _brandSubtitle(b),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF8E8E93),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF0A84FF),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: Color(0xFFFFFFFF),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraPickerSheet extends StatelessWidget {
  const _CameraPickerSheet({
    required this.cameras,
    required this.selectedCameraId,
    this.profileModel,
  });

  final List<ProfileCamera> cameras;
  final String? selectedCameraId;
  final String? profileModel;

  String? _cameraSubtitle(ProfileCamera c) {
    final parts = <String>[];
    if (c.fields.containsKey('focalLength35mm')) {
      parts.add('${c.fields['focalLength35mm']}mm');
    } else if (c.fields.containsKey('focalLength')) {
      parts.add('${c.fields['focalLength']}mm');
    }
    if (c.fields.containsKey('fNumber')) {
      parts.add('f/${c.fields['fNumber']}');
    }
    if (parts.isNotEmpty) {
      return parts.join(' · ');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lensSummary = cameras.length == 1
        ? '1 lens'
        : '${cameras.length} lenses';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Select Camera',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                      if (profileModel != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              profileModel!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF8E8E93),
                              ),
                            ),
                            Text(
                              ' · $lensSummary',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF8E8E93),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(22),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2C2C2E),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E)),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: cameras.length,
                  separatorBuilder: (context, index) => const Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: Color(0xFF2C2C2E),
                  ),
                  itemBuilder: (context, index) {
                    final c = cameras[index];
                    final isSelected = selectedCameraId == c.id;
                    final subtitle = _cameraSubtitle(c);
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(c),
                      child: Container(
                        color: isSelected
                            ? const Color(0xFF2C2C2E)
                            : Colors.transparent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.name,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      color: isSelected
                                          ? const Color(0xFF0A84FF)
                                          : Colors.white,
                                    ),
                                  ),
                                  if (subtitle != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF8E8E93),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (isSelected)
                              Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF0A84FF),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: Color(0xFFFFFFFF),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickPrivacyScrubberSheet extends StatefulWidget {
  const _QuickPrivacyScrubberSheet({required this.supportedFields});
  final Set<String> supportedFields;

  @override
  State<_QuickPrivacyScrubberSheet> createState() =>
      _QuickPrivacyScrubberSheetState();
}

class _QuickPrivacyScrubberSheetState
    extends State<_QuickPrivacyScrubberSheet> {
  bool _stripLocation = true;
  bool _stripHardware = true;
  bool _stripDates = false;
  bool _stripAuthor = true;

  static const _locationFields = {'latitude', 'longitude', 'altitude'};
  static const _hardwareFields = {
    'serialNumber',
    'lensSerialNumber',
    'cameraOwnerName',
    'software',
    'hostComputer',
  };
  static const _dateFields = {
    'dateTimeOriginal',
    'createDate',
    'modifyDate',
    'offsetTimeOriginal',
    'offsetTimeDigitized',
    'offsetTime',
    'quickTimeCreationDate',
    'movieCreateDate',
    'movieModifyDate',
    'trackCreateDate',
    'trackModifyDate',
    'mediaCreateDate',
    'mediaModifyDate',
  };
  static const _authorFields = {
    'artist',
    'copyright',
    'userComment',
    'imageDescription',
  };

  Set<String> _calculateFields() {
    final fields = <String>{};
    if (_stripLocation) fields.addAll(_locationFields);
    if (_stripHardware) fields.addAll(_hardwareFields);
    if (_stripDates) fields.addAll(_dateFields);
    if (_stripAuthor) fields.addAll(_authorFields);
    return fields.where((f) => widget.supportedFields.contains(f)).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final eligible = _calculateFields();
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3A3C),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2A3E),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      color: Color(0xFF0A84FF),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quick Privacy Scrubber',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Select categories to strip before sharing',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8E8E93),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2C2C2E),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Color(0xFF8E8E93),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF2C2C2E)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _buildToggleRow(
                      icon: Icons.location_off_outlined,
                      title: 'Location & GPS Geotags',
                      subtitle: 'Latitude, longitude, altitude coordinates',
                      value: _stripLocation,
                      onChanged: (v) => setState(() => _stripLocation = v),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFF2C2C2E),
                      indent: 52,
                    ),
                    _buildToggleRow(
                      icon: Icons.perm_device_information_outlined,
                      title: 'Hardware & Device Identifiers',
                      subtitle: 'Camera/lens serial numbers, owner name, host',
                      value: _stripHardware,
                      onChanged: (v) => setState(() => _stripHardware = v),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFF2C2C2E),
                      indent: 52,
                    ),
                    _buildToggleRow(
                      icon: Icons.person_outline_rounded,
                      title: 'Author & Copyright Data',
                      subtitle: 'Artist, copyright text, user comments',
                      value: _stripAuthor,
                      onChanged: (v) => setState(() => _stripAuthor = v),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: Color(0xFF2C2C2E),
                      indent: 52,
                    ),
                    _buildToggleRow(
                      icon: Icons.schedule_outlined,
                      title: 'Capture Timestamps',
                      subtitle: 'Strip creation dates & UTC offsets',
                      value: _stripDates,
                      onChanged: (v) => setState(() => _stripDates = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                key: const Key('applyPrivacyScrub'),
                onPressed: eligible.isEmpty
                    ? null
                    : () => Navigator.pop(context, eligible),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text('Apply Privacy Scrub (${eligible.length} fields)'),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      activeTrackColor: const Color(0xFF0A84FF),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: value ? const Color(0xFF1E2A3E) : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 16,
          color: value ? const Color(0xFF0A84FF) : const Color(0xFF8E8E93),
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
      ),
    );
  }
}
