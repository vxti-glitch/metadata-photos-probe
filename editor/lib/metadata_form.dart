import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_profiles.dart';
import 'editor_controller.dart';
import 'media_bridge.dart' show simplifyUserError;
import 'media_models.dart';
import 'metadata_patch.dart';
import 'metadata_dates.dart';
import 'editor_app.dart' show WorkflowNote;
import 'app_theme.dart';
import 'media_preview.dart';

enum _FormStage { edit, review, result }

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
    this.fillAvailableSpace = false,
  });
  final EditorController controller;
  final MediaSession session;
  final bool batch;
  final bool fillAvailableSpace;
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
  _FormStage _stage = _FormStage.edit;
  Map<String, MetadataPatch>? _reviewedPatches;
  String? _reviewedDraftSignature;
  Map<String, String> _reviewedNames = {};
  bool _preparingDraft = false;
  bool _autoMatched = false;
  bool _viewingExistingCopy = false;
  Map<String, String?> _processingIdsBefore = {};
  Set<String> _attemptedBatchIds = {};
  bool _acknowledgeBatchExport = false;
  String? _acknowledgedBatchOutputs;
  bool _quickDateSelected = false;
  int _batchStaggerSeconds = 0;
  CameraProfile? profile;
  ProfileCamera? camera;
  String? brand;
  late RandomizationSettings settings;
  String? formError;
  MetadataPatch? profileBaseline;
  MetadataPatch? _generatedDateFamily;
  final explicitOverrides = <String>{};
  bool _appliedFeedback = false;
  Timer? _appliedTimer;
  @override
  void initState() {
    super.initState();
    settings = const RandomizationSettings();
    _preparingDraft = widget.fillAvailableSpace;
    if (widget.fillAvailableSpace &&
        !widget.batch &&
        widget.session.processing != null) {
      _viewingExistingCopy = true;
      _stage = _FormStage.result;
      _processingIdsBefore = {widget.session.id: null};
    }
    if (widget.fillAvailableSpace &&
        widget.batch &&
        widget.controller.queue.any(
          (item) => widget.controller.batchSelection.contains(item.sessionId),
        )) {
      _viewingExistingCopy = true;
      _stage = _FormStage.result;
      _attemptedBatchIds = widget.controller.queue
          .where(
            (item) => widget.controller.batchSelection.contains(item.sessionId),
          )
          .map((item) => item.sessionId)
          .toSet();
      _processingIdsBefore = {for (final id in _attemptedBatchIds) id: null};
    }
    _tabIndex = widget.fillAvailableSpace ? 1 : 0;
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: _tabIndex,
    );
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
    if (patch != null && !widget.fillAvailableSpace) {
      _apply(patch, notify: false);
    }

    catalog = loadCameraProfiles()
        .then((profiles) async {
          if (mounted) {
            if (widget.fillAvailableSpace) {
              await _prepareAutomaticDraft(profiles);
            } else {
              await _restoreSavedProfile(profiles);
            }
          }
          return profiles;
        })
        .catchError((Object failure) {
          if (mounted) {
            setState(() {
              _preparingDraft = false;
              formError = 'The camera catalog is unavailable. Use Manual editing or try opening the file again.';
              if (widget.fillAvailableSpace && profileBaseline == null) {
                _apply(
                  _standaloneAutomaticDates(MetadataPatch(), widget.session),
                  notify: false,
                );
              }
            });
          }
          return <CameraProfile>[];
        });
  }

  Future<void> _prepareAutomaticDraft(List<CameraProfile> profiles) async {
    Map<String, String>? host;
    try {
      host = await widget.controller.getHostDevice();
    } catch (_) {
      // An unknown phone never becomes an invented camera profile.
    }
    if (!mounted) return;
    final matched = profiles
        .where((p) => p.id == host?['profileId'])
        .firstOrNull;
    final saved = profiles
        .where((p) => p.id == widget.controller.selectedProfileId)
        .firstOrNull;
    setState(() {
      profile ??= matched ?? saved;
      brand = profile?.brand;
      _autoMatched = matched != null && profile?.id == matched.id;
      final savedCamera = profile?.id == widget.controller.selectedProfileId
          ? profile?.cameras
                .where((c) => c.id == widget.controller.selectedCameraId)
                .firstOrNull
          : null;
      camera ??= savedCamera ?? profile?.cameras.firstOrNull;
      if (profile != null && camera != null) {
        _applySelectedProfile();
      } else {
        _apply(
          _standaloneAutomaticDates(MetadataPatch(), widget.session),
          notify: false,
        );
      }
      _preparingDraft = false;
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
    if (mounted) {
      setState(() {
        if (_acknowledgeBatchExport &&
            _acknowledgedBatchOutputs != _batchOutputSignature()) {
          _acknowledgeBatchExport = false;
          _acknowledgedBatchOutputs = null;
        }
      });
    }
  }

  String _batchOutputSignature() =>
      (_newBatchOutputs()
              .map((session) => '${session.id}:${session.processing!.id}')
              .toList()
            ..sort())
          .join('|');

  void _applySelectedProfile() {
    final keptOverrides = Set<String>.of(explicitOverrides);
    final oldInputs = {for (final key in keptOverrides) key: inputs[key]?.text};
    final oldModes = {for (final key in keptOverrides) key: modes[key]};
    _apply(_profilePatch(widget.session), notify: false, fromProfile: true);
    for (final key in keptOverrides) {
      if (oldInputs[key] != null) inputs[key]!.text = oldInputs[key]!;
      if (oldModes[key] != null) modes[key] = oldModes[key]!;
    }
    explicitOverrides.addAll(keptOverrides);
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

  Set<String> get supported {
    final capabilities = widget.controller.capabilities!;
    if (!widget.batch) {
      return capabilities.fieldsFor(widget.session.inspection.kind);
    }
    return widget.controller.sessions
        .where(
          (session) => widget.controller.batchSelection.contains(session.id),
        )
        .expand((session) => capabilities.fieldsFor(session.inspection.kind))
        .toSet();
  }

  void _apply(
    MetadataPatch patch, {
    bool notify = true,
    bool fromProfile = false,
  }) {
    profileBaseline = fromProfile ? patch : null;
    _quickDateSelected = false;
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

  bool get _hasCompetingMetadata {
    if (widget.batch) {
      return widget.controller.sessions
          .where((s) => widget.controller.batchSelection.contains(s.id))
          .any(
            (s) =>
                s.inspection.structure['competingMetadata'] == 'true' ||
                s.inspection.notes.any(
                  (n) =>
                      n.contains('Additional XMP') ||
                      n.contains('Additional PNG text') ||
                      n.contains('competing'),
                ),
          );
    }
    return widget.session.inspection.structure['competingMetadata'] == 'true' ||
        widget.session.inspection.notes.any(
          (n) =>
              n.contains('Additional XMP') ||
              n.contains('Additional PNG text') ||
              n.contains('competing'),
        );
  }

  bool get _hasTimedMetadata {
    if (widget.batch) {
      return widget.controller.sessions
          .where((s) => widget.controller.batchSelection.contains(s.id))
          .any(
            (s) =>
                s.inspection.structure['trackTypes']?.contains('meta') ==
                    true ||
                s.inspection.notes.any((n) => n.contains('timed metadata')),
          );
    }
    return widget.session.inspection.structure['trackTypes']?.contains(
              'meta',
            ) ==
            true ||
        widget.session.inspection.notes.any(
          (n) => n.contains('timed metadata'),
        );
  }

  MetadataPatch _patch({bool allowEmpty = false, Set<String>? fields}) {
    final values = <String, Object>{};
    final removed = <String>[];
    for (final f in metadataFields) {
      if (!(fields ?? supported).contains(f.key)) continue;
      if (modes[f.key] == 'remove') {
        if (!_hasCompetingMetadata) {
          removed.add(f.key);
        }
      } else if (modes[f.key] == 'set') {
        if (_hasTimedMetadata &&
            [
              'latitude',
              'longitude',
              'altitude',
              'imageDirection',
            ].contains(f.key)) {
          continue;
        }
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
    final rawGenerated = _completeGeneratedDateFamily(
      captureDatePatch(date, image: source.inspection.kind.isImage),
    );
    _generatedDateFamily = rawGenerated;
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
    final fields = widget.batch
        ? supported
        : widget.controller.capabilities!.fieldsFor(source.inspection.kind);
    final raw = settings.generate(
      profile!,
      camera!,
      source.inspection.kind,
      random,
      DateTime.now(),
    );
    _generatedDateFamily = _completeGeneratedDateFamily(
      MetadataPatch(
        values: {
          for (final entry in raw.values.entries)
            if (_dateFieldKeys.contains(entry.key)) entry.key: entry.value,
        },
      ),
    );
    final patch = MetadataPatch(
      values: {
        for (final entry in {
          ...raw.values,
          ..._generatedDateFamily!.values,
        }.entries)
          if (fields.contains(entry.key)) entry.key: entry.value,
      },
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
      final presentKeys = widget.batch
          ? widget.controller.sessions
                .where((s) => widget.controller.batchSelection.contains(s.id))
                .expand((s) => s.inspection.metadata.keys)
                .toSet()
          : source.inspection.metadata.keys.toSet();
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

  MetadataPatch _completeGeneratedDateFamily(MetadataPatch generated) {
    final stamp = generated.values['dateTimeOriginal'];
    if (!widget.batch ||
        widget.session.inspection.kind.isImage ||
        stamp is! String ||
        !isStrictISODate(stamp)) {
      return generated;
    }
    // Freeze the phone's generated zone alongside the instant. Otherwise a
    // video-first batch silently adopts each image's old zone despite Set intent.
    // Explicit Keep overrides still remove these generated zones when resolving.
    final photoDates = captureDatePatch(
      DateTime.parse(stamp).toLocal(),
      image: true,
    );
    return MetadataPatch(
      values: {
        ...generated.values,
        for (final key in sharedDateOffsets.values)
          key: photoDates.values[key]!,
      },
      removals: generated.removals,
    );
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

  static final _dateFieldKeys = {
    ...sharedDateOffsets.keys,
    ...sharedDateOffsets.values,
    ...movieDateKeys,
    'quickTimeCreationDate',
  };

  String get _dateIntent {
    if (_dateFieldKeys.any(
      (key) =>
          explicitOverrides.contains(key) &&
          (modes[key] == 'set' || modes[key] == 'remove'),
    )) {
      return _quickDateSelected ? 'set' : 'custom';
    }
    if (settings.randomizeDates) return 'randomize';
    if (_quickDateSelected) return 'set';
    if (_dateFieldKeys.any(
      (key) => modes[key] == 'set' || modes[key] == 'remove',
    )) {
      return 'custom';
    }
    return 'keep';
  }

  String _draftSignature() => jsonEncode({
    'modes': {for (final key in (modes.keys.toList()..sort())) key: modes[key]},
    'inputs': {
      for (final key in (inputs.keys.toList()..sort())) key: inputs[key]!.text,
    },
    'settings': settings.toMap(),
    'profile': profile?.id,
    'camera': camera?.id,
    'overrides': explicitOverrides.toList()..sort(),
    'batchStaggerSeconds': _batchStaggerSeconds,
    'quickDateSelected': _quickDateSelected,
    if (widget.batch)
      'selectedSources':
          (widget.controller.sessions
              .where(
                (session) =>
                    widget.controller.batchSelection.contains(session.id),
              )
              .map((session) => '${session.id}:${session.inspection.kind.name}')
              .toList()
            ..sort()),
  });

  void _clearDateDrafts() {
    _quickDateSelected = false;
    for (final key in _dateFieldKeys) {
      if (!inputs.containsKey(key)) continue;
      modes[key] = 'keep';
      inputs[key]!.text =
          widget.session.inspection.metadata[key] ??
          (key == 'lensModel'
              ? widget.session.inspection.metadata['lens']
              : null) ??
          '';
      explicitOverrides.remove(key);
    }
  }

  Future<void> _setDateIntent(String intent) async {
    if (widget.controller.busy) return;
    if (intent == 'keep' || intent == 'randomize') {
      _clearDateDrafts();
      _settingsChanged(settings.withAutomaticDates(intent == 'randomize'));
      return;
    }
    final previousSettings = settings;
    settings = settings.withAutomaticDates(false);
    final selected = await _pickCaptureDate();
    if (!selected) settings = previousSettings;
  }

  Widget _automaticDates() {
    if (!widget.fillAvailableSpace) {
      return Column(
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
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Date & time',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const Key('dateIntentSegment'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'keep', label: Text('Keep original')),
            ButtonSegment(value: 'set', label: Text('Set')),
            ButtonSegment(value: 'randomize', label: Text('Randomize')),
          ],
          emptySelectionAllowed: true,
          selected: _dateIntent == 'custom' ? {} : {_dateIntent},
          onSelectionChanged: widget.controller.busy
              ? null
              : (selection) {
                  if (selection.isNotEmpty) _setDateIntent(selection.first);
                },
        ),
        const SizedBox(height: 6),
        Text(switch (_dateIntent) {
          'set' =>
            'Choose a capture time; supported date fields update together.',
          'randomize' =>
            'Create a randomized capture time within your date settings.',
          'custom' =>
            'Custom date edits or removals are staged in Advanced metadata.',
          _ => 'Preserve each original date and time.',
        }, style: TextStyle(color: AppTheme.of(context).muted, fontSize: 12)),
        if (_dateIntent == 'set')
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('changeCaptureDate'),
              onPressed: widget.controller.busy ? null : _pickCaptureDate,
              icon: const Icon(Icons.edit_calendar_outlined, size: 16),
              label: const Text('Change date & time'),
            ),
          ),
      ],
    );
  }

  Future<bool> _pickCaptureDate() async {
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
    if (date == null || !mounted || widget.controller.busy) return false;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted || widget.controller.busy) return false;
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
      _quickDateSelected = true;
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
    return true;
  }

  Future<Map<String, MetadataPatch>> _resolvePatches() async {
    // Values have already been generated into the draft. Resolving a review
    // shapes the same frozen patch for every file; it never draws new values.
    final sources = widget.batch
        ? widget.controller.sessions
              .where((s) => widget.controller.batchSelection.contains(s.id))
              .toList()
        : [widget.session];
    var manual = _patch(allowEmpty: true, fields: supported);
    if (settings.randomizeDates && _generatedDateFamily != null) {
      manual = MetadataPatch(
        values: {
          for (final entry in _generatedDateFamily!.values.entries)
            if (!manual.removals.contains(entry.key) &&
                !(explicitOverrides.contains(entry.key) &&
                    modes[entry.key] == 'keep'))
              entry.key: entry.value,
          ...manual.values,
        },
        removals: manual.removals,
      );
    }
    if (!widget.fillAvailableSpace && profileBaseline == null) {
      manual = _standaloneAutomaticDates(manual, widget.session);
    }
    final kept = explicitOverrides.where((key) => modes[key] == 'keep').toSet();
    final fixedDates = sharedDateOffsets.keys
        .where(
          (key) =>
              manual.values.containsKey(key) &&
              (explicitOverrides.contains(key) ||
                  (profileBaseline != null &&
                      manual.values[key] != profileBaseline!.values[key])),
        )
        .toSet();
    final patches = <String, MetadataPatch>{};
    for (final source in sources) {
      var shaped = manual;
      if (profileBaseline != null && source.inspection.kind.isImage) {
        final withZones = MetadataPatch(
          values: {
            ...manual.values,
            for (final key in sharedDateOffsets.values)
              if (kept.contains(key) &&
                  !manual.values.containsKey(key) &&
                  profileBaseline!.values.containsKey(key))
                key: profileBaseline!.values[key]!,
          },
          removals: manual.removals,
        );
        final normalized = randomDatesWithKeptZones(
          withZones,
          keepFields: kept,
          destinationMetadata: source.inspection.metadata,
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
      final item = datesForMedia(
        shaped,
        image: source.inspection.kind.isImage,
        keptOffsets: source.inspection.kind.isImage
            ? source.inspection.metadata
            : widget.session.inspection.metadata,
        keepFields: kept,
      );
      final fields = widget.controller.capabilities!.fieldsFor(
        source.inspection.kind,
      );
      patches[source.id] = MetadataPatch(
        values: {
          for (final e in item.values.entries)
            if (fields.contains(e.key)) e.key: e.value,
        },
        removals: item.removals.where(fields.contains),
      );
    }
    return offsetBatchDatePatches(
      patches,
      Duration(seconds: _batchStaggerSeconds),
    );
  }

  Future<void> _reviewChanges() async {
    try {
      if (_reviewedPatches != null &&
          _reviewedDraftSignature == _draftSignature()) {
        setState(() {
          _acknowledgeBatchExport = false;
          _stage = _FormStage.review;
          formError = null;
        });
        return;
      }
      final patches = await _resolvePatches();
      if (patches.values.every(
        (patch) => patch.values.isEmpty && patch.removals.isEmpty,
      )) {
        throw const FormatException('Choose at least one metadata change.');
      }
      final signature = _draftSignature();
      final changedIds = patches.entries
          .where(
            (e) => e.value.values.isNotEmpty || e.value.removals.isNotEmpty,
          )
          .map((e) => e.key)
          .toList();
      final names = await widget.controller.reserveOutputNames(changedIds);
      if (!mounted) return;
      if (names.length != changedIds.length) {
        setState(
          () => formError =
              widget.controller.error ??
              'Output names could not be prepared. Try reviewing again.',
        );
        return;
      }
      if (signature != _draftSignature()) {
        setState(
          () => formError =
              'Your edits changed while preparing copies. Review them again.',
        );
        return;
      }
      setState(() {
        _reviewedNames = Map.unmodifiable(names);
        _reviewedPatches = Map.unmodifiable(patches);
        _reviewedDraftSignature = _draftSignature();
        _acknowledgeBatchExport = false;
        _stage = _FormStage.review;
        formError = null;
      });
    } on FormatException catch (e) {
      widget.controller.recordError(e.message);
      if (mounted) setState(() => formError = e.message);
    }
  }

  Future<void> _createReviewedCopy() async {
    final patches = _reviewedPatches;
    if (patches == null || widget.controller.busy) return;
    try {
      _acknowledgeBatchExport = false;
      _viewingExistingCopy = false;
      _processingIdsBefore = {
        for (final session in widget.controller.sessions)
          session.id: session.processing?.id,
      };
      if (widget.batch) {
        final changed = {
          for (final entry in patches.entries)
            if (entry.value.values.isNotEmpty ||
                entry.value.removals.isNotEmpty)
              entry.key: entry.value,
        };
        _attemptedBatchIds = changed.keys.toSet();
        if (changed.isNotEmpty) await widget.controller.processBatch(changed);
      } else {
        final patch = patches[widget.session.id];
        if (patch == null) return;
        _attemptedBatchIds = {widget.session.id};
        await widget.controller.processMetadata(patch);
      }
      if (mounted) setState(() => _stage = _FormStage.result);
    } on FormatException catch (e) {
      widget.controller.recordError(e.message);
      if (mounted) setState(() => formError = e.message);
    }
  }

  Future<void> _process() async {
    try {
      final patches = await _resolvePatches();
      if (widget.batch) {
        await widget.controller.processBatch(patches);
      } else {
        await widget.controller.processMetadata(patches[widget.session.id]!);
      }
      if (mounted) setState(() => formError = null);
    } on FormatException catch (e) {
      widget.controller.recordError(e.message);
      if (mounted) setState(() => formError = e.message);
    }
  }

  void _returnToEdit() => setState(() {
    if (_stage == _FormStage.result) {
      _reviewedPatches = null;
      _reviewedDraftSignature = null;
      _reviewedNames = {};
    }
    _stage = _FormStage.edit;
  });

  Future<void> _openModelSearchSheet(
    BuildContext context,
    List<CameraProfile> availableProfiles,
  ) async {
    final selected = await showModalBottomSheet<CameraProfile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.of(context).raised,
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
        _autoMatched = false;
        camera = profile!.cameras.first;
        _appliedFeedback = false;
        _applySelectedProfile();
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
      backgroundColor: AppTheme.of(context).raised,
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
        _autoMatched = false;
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
      backgroundColor: AppTheme.of(context).raised,
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
        _applySelectedProfile();
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
        color: AppTheme.of(context).surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.of(context).border, width: 1),
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
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          color: AppTheme.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: enabled
                              ? (isPlaceholder
                                    ? AppTheme.of(context).subtle
                                    : AppTheme.of(context).text)
                              : AppTheme.of(context).subtle,
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
                      color: enabled
                          ? AppTheme.of(context).accent
                          : AppTheme.of(context).subtle,
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
        color: isMismatch
            ? AppTheme.of(context).errorSurface
            : AppTheme.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMismatch
              ? AppTheme.of(context).errorBorder
              : AppTheme.of(context).border,
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
                color: isMismatch
                    ? AppTheme.of(context).error
                    : AppTheme.of(context).accent,
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
                    color: isMismatch
                        ? AppTheme.of(context).error
                        : AppTheme.of(context).text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.of(context).raised,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Output File',
                        style: TextStyle(
                          color: AppTheme.of(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        '${output.inspection.kind.label} · ${output.inspection.sizeLabel}',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: AppTheme.of(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  output.outputDisplayName ?? 'Processed copy',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: AppTheme.of(context).text,
                  ),
                ),
                const SizedBox(height: 8),
                Divider(height: 1, color: AppTheme.of(context).border),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      output.autoExportFolder == null
                          ? Icons.phone_iphone_outlined
                          : Icons.folder_outlined,
                      size: 16,
                      color: AppTheme.of(context).accent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        output.autoExportFolder == null
                            ? 'Held in the app. Export to Files after reviewing the checks.'
                            : 'Saved to: ${output.autoExportFolder}',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.of(context).muted,
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
            Text(
              'A preservation check failed. Export blocked.',
              style: TextStyle(color: AppTheme.of(context).error, fontSize: 13),
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
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.of(context).muted,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (!widget.fillAvailableSpace) ...[
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
                    label: const Text('Share copy'),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('openICloud'),
            onPressed: controller.busy ? null : controller.openICloud,
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Open iCloud Photos'),
          ),
          const SizedBox(height: 6),
          Text(
            'Upload the exported file in Safari, then let it sync to Photos.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.of(context).muted, fontSize: 11),
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
    final content = _stageContent(context);
    if (!widget.fillAvailableSpace) return content;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: content,
          ),
        ),
        _primaryActionBar(),
      ],
    );
  }

  Widget _primaryActionBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppTheme.of(context).raised,
        border: Border(top: BorderSide(color: AppTheme.of(context).border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _stage == _FormStage.result
            ? _resultFooterActions()
            : [
                FilledButton.icon(
                  key: Key('primary${_stage.name}Action'),
                  onPressed:
                      widget.controller.busy ||
                          (_stage == _FormStage.edit && _preparingDraft)
                      ? null
                      : () {
                          switch (_stage) {
                            case _FormStage.edit:
                              _reviewChanges();
                            case _FormStage.review:
                              _createReviewedCopy();
                            case _FormStage.result:
                              _returnToEdit();
                          }
                        },
                  icon: Icon(switch (_stage) {
                    _FormStage.edit => Icons.fact_check_outlined,
                    _FormStage.review => Icons.auto_fix_high_outlined,
                    _FormStage.result => Icons.edit_outlined,
                  }),
                  label: Text(switch (_stage) {
                    _FormStage.edit =>
                      widget.batch
                          ? 'Review ${widget.controller.batchSelection.length} files'
                          : 'Review changes',
                    _FormStage.review =>
                      widget.batch
                          ? 'Create ${_reviewedNames.length} copies'
                          : 'Create edited copy',
                    _FormStage.result => 'Edit changes',
                  }),
                ),
                if (_stage == _FormStage.edit) ...[
                  TextButton(
                    key: const Key('savingGuide'),
                    onPressed: _showSavingGuide,
                    child: const Text('How saving works'),
                  ),
                  Text(
                    'Your originals stay unchanged.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.of(context).muted,
                      fontSize: 11,
                    ),
                  ),
                ],
                if (_stage == _FormStage.review)
                  TextButton(
                    key: const Key('returnToEdit'),
                    onPressed: widget.controller.busy ? null : _returnToEdit,
                    child: const Text('Back to edit'),
                  ),
              ],
      ),
    ),
  );

  List<Widget> _resultFooterActions() {
    if (!widget.batch) {
      final current =
          widget.controller.sessions
              .where((session) => session.id == widget.session.id)
              .firstOrNull ??
          widget.session;
      final output = current.processing;
      final isNew =
          output != null &&
          output.id != _processingIdsBefore[widget.session.id];
      final canExport = isNew && widget.controller.canExport;
      return [
        FilledButton.icon(
          key: const Key('exportFiles'),
          onPressed: canExport ? widget.controller.exportFiles : null,
          icon: const Icon(Icons.folder_shared_outlined),
          label: const Text('Export to Files'),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 0,
          children: [
            TextButton.icon(
              key: const Key('shareFiles'),
              onPressed: canExport ? widget.controller.shareFiles : null,
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('Share copy'),
            ),
            TextButton(
              key: const Key('primaryresultAction'),
              onPressed: widget.controller.busy ? null : _returnToEdit,
              child: const Text('Back to edit'),
            ),
          ],
        ),
      ];
    }
    final outputs = _newBatchOutputs();
    final canExport =
        outputs.isNotEmpty &&
        outputs.every(
          (session) =>
              !session.processing!.integrity.hasMismatch &&
              (!session.processing!.integrity.needsAcknowledgment ||
                  _acknowledgeBatchExport),
        ) &&
        !widget.controller.busy;
    return [
      FilledButton.icon(
        key: const Key('exportReadyBatchCopies'),
        onPressed: canExport
            ? () => widget.controller.exportSelectedBatch(
                acknowledgeIncomplete: _acknowledgeBatchExport,
                onlyReady: true,
              )
            : null,
        icon: const Icon(Icons.folder_shared_outlined),
        label: const Text('Export processed copies'),
      ),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 0,
        children: [
          TextButton.icon(
            key: const Key('shareReadyBatchCopies'),
            onPressed: canExport
                ? () => widget.controller.shareSelectedBatch(
                    acknowledgeIncomplete: _acknowledgeBatchExport,
                    onlyReady: true,
                  )
                : null,
            icon: const Icon(Icons.ios_share_outlined),
            label: const Text('Share copies'),
          ),
          TextButton(
            key: const Key('primaryresultAction'),
            onPressed: widget.controller.busy ? null : _returnToEdit,
            child: const Text('Back to edit'),
          ),
        ],
      ),
    ];
  }

  List<MediaSession> _newBatchOutputs() {
    final queueById = {
      for (final item in widget.controller.queue) item.sessionId: item,
    };
    return widget.controller.sessions.where((session) {
      return _attemptedBatchIds.contains(session.id) &&
          session.processing != null &&
          session.processing!.id != _processingIdsBefore[session.id] &&
          queueById[session.id]?.status == 'completed';
    }).toList();
  }

  Widget _reviewContent(BuildContext context) {
    final patches = _reviewedPatches!;
    final sessions = widget.controller.sessions
        .where((session) => patches.containsKey(session.id))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Review changes',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          widget.batch
              ? '${patches.values.where((patch) => patch.values.isNotEmpty || patch.removals.isNotEmpty).length} copies planned · unchanged files will be skipped'
              : 'Check the requested changes before creating a copy.',
          style: TextStyle(color: AppTheme.of(context).muted),
        ),
        const SizedBox(height: 16),
        if (widget.batch)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Shared metadata',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  for (final key in ['model', 'iso', 'dateTimeOriginal'])
                    if (patches.values.first.values.containsKey(key))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${_fieldLabel(key)}: ${patches.values.first.values[key]}',
                        ),
                      ),
                  const SizedBox(height: 8),
                  const Text(
                    'The same supported changes apply to every selected file. Kept fields and unavailable format fields can differ.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        for (final session in sessions)
          _reviewSessionCard(session, patches[session.id]!),
        const SizedBox(height: 8),
        Text(
          'Fields omitted from this review remain unchanged, including dates and location.',
          style: TextStyle(
            color: AppTheme.of(context).muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Creating a copy leaves the selected original untouched.',
          style: TextStyle(color: AppTheme.of(context).muted, fontSize: 13),
        ),
      ],
    );
  }

  Widget _reviewSessionCard(MediaSession session, MetadataPatch patch) {
    String originalValue(String key) =>
        session.inspection.metadata[key] ??
        (key == 'lensModel' ? session.inspection.metadata['lens'] : null) ??
        'Not present';
    final changes = <Widget>[
      for (final entry in patch.values.entries)
        ListTile(
          dense: true,
          title: Text(_fieldLabel(entry.key)),
          subtitle: Text('${originalValue(entry.key)}  →  ${entry.value}'),
        ),
      for (final key in patch.removals)
        ListTile(
          dense: true,
          title: Text(_fieldLabel(key)),
          subtitle: Text(
            session.inspection.metadata[key] == null &&
                    (key != 'lensModel' ||
                        session.inspection.metadata['lens'] == null)
                ? 'Not reported  →  Remove if present'
                : '${originalValue(key)}  →  Removed',
          ),
        ),
    ];
    if (widget.fillAvailableSpace) {
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ExpansionTile(
          key: ValueKey('reviewFile-${session.id}'),
          leading: MediaPreview(
            session: session,
            height: 48,
            width: 48,
            borderRadius: BorderRadius.circular(8),
          ),
          title: Text(session.displayName),
          subtitle: Text(
            _reviewedNames[session.id] == null
                ? 'No supported changes — skipped'
                : '→ ${_reviewedNames[session.id]}',
          ),
          children: changes.isEmpty
              ? [
                  const ListTile(
                    title: Text('Unchanged — no copy will be created'),
                  ),
                ]
              : changes,
        ),
      );
    }
    return Card(
      color: AppTheme.of(context).surface,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(session.displayName),
              subtitle: Text(
                '${session.inspection.kind.label} · ${session.inspection.sizeLabel}',
              ),
            ),
            const Divider(height: 1),
            if (changes.isEmpty)
              const ListTile(
                title: Text('Unchanged — no copy will be created'),
                subtitle: Text('No supported fields change for this file.'),
              )
            else
              ...changes,
          ],
        ),
      ),
    );
  }

  String _fieldLabel(String key) =>
      metadataFields
          .where((field) => field.key == key)
          .map((field) => field.label)
          .firstOrNull ??
      key;

  String _integrityStatusLabel(IntegrityReport report) => report.hasMismatch
      ? 'Verification failed'
      : report.needsAcknowledgment
      ? 'Verification limited'
      : 'Verification passed';

  Widget _integritySummary(IntegrityReport report, String outputId) =>
      ExpansionTile(
        key: ValueKey('batchIntegrityDetails-$outputId'),
        title: const Text('Details', style: TextStyle(fontSize: 13)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        shape: const Border(),
        collapsedShape: const Border(),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final check in report.checks)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${check.name}: ${check.status} — ${check.detail}',
                    style: TextStyle(
                      color: AppTheme.of(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              for (final limitation in report.limitations)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Limitation: $limitation',
                    style: TextStyle(
                      color: AppTheme.of(context).warning,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );

  Widget _resultContent(BuildContext context) {
    final controller = widget.controller;
    if (!widget.batch) {
      final current =
          controller.sessions
              .where((session) => session.id == widget.session.id)
              .firstOrNull ??
          widget.session;
      final output = current.processing;
      final isNew =
          output != null &&
          output.id != _processingIdsBefore[widget.session.id];
      if (isNew) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              output.integrity.hasMismatch
                  ? _viewingExistingCopy
                        ? 'Saved copy failed integrity checks'
                        : 'New output failed integrity checks'
                  : _viewingExistingCopy
                  ? 'Saved copy'
                  : 'Copy created',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            _buildProcessingResults(context, output),
          ],
        );
      }
      return const Text(
        'No processed copy is available. Review the error, then edit and try again.',
      );
    }
    final sessions = controller.sessions
        .where((session) => controller.batchSelection.contains(session.id))
        .toList();
    final queueById = {
      for (final item in controller.queue) item.sessionId: item,
    };
    final withOutput = _newBatchOutputs();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Batch results', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${withOutput.length} ${_viewingExistingCopy ? 'saved copies available' : 'new copies created'} · ${_attemptedBatchIds.length - withOutput.length} attempted files need attention',
          style: TextStyle(color: AppTheme.of(context).muted),
        ),
        if (withOutput.any(
          (session) => session.processing!.integrity.needsAcknowledgment,
        )) ...[
          const SizedBox(height: 8),
          Text(
            'Some preservation checks have limited verification. Review each copy’s Details before exporting.',
            key: const Key('batchVerificationNotice'),
            style: TextStyle(color: AppTheme.of(context).muted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 12),
        for (final session in sessions)
          Card(
            color: AppTheme.of(context).surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  ListTile(
                    title: Text(session.displayName),
                    subtitle: Text(
                      !_attemptedBatchIds.contains(session.id)
                          ? 'Unchanged — no copy created'
                          : queueById[session.id]?.status == 'completed' &&
                                session.processing != null &&
                                session.processing!.id !=
                                    _processingIdsBefore[session.id]
                          ? '${session.processing!.outputDisplayName ?? 'Processed copy'}\n${_viewingExistingCopy ? 'Saved copy' : 'Copy created'} · ${_integrityStatusLabel(session.processing!.integrity)}'
                          : queueById[session.id]?.message ??
                                'No new copy created',
                    ),
                    trailing: Icon(
                      !_attemptedBatchIds.contains(session.id)
                          ? Icons.remove_circle_outline
                          : queueById[session.id]?.status == 'completed' &&
                                session.processing != null &&
                                session.processing!.id !=
                                    _processingIdsBefore[session.id]
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: !_attemptedBatchIds.contains(session.id)
                          ? AppTheme.of(context).muted
                          : queueById[session.id]?.status == 'completed' &&
                                session.processing != null &&
                                session.processing!.id !=
                                    _processingIdsBefore[session.id]
                          ? AppTheme.of(context).accent
                          : AppTheme.of(context).warning,
                    ),
                  ),
                  if (_attemptedBatchIds.contains(session.id) &&
                      session.processing != null &&
                      session.processing!.id !=
                          _processingIdsBefore[session.id])
                    _integritySummary(
                      session.processing!.integrity,
                      session.processing!.id,
                    ),
                ],
              ),
            ),
          ),
        if (controller.queue.any(
          (item) =>
              _attemptedBatchIds.contains(item.sessionId) &&
              item.status != 'completed',
        ))
          OutlinedButton.icon(
            key: const Key('retryUnfinishedBatch'),
            onPressed: controller.busy || !controller.ready
                ? null
                : () {
                    setState(() {
                      _acknowledgeBatchExport = false;
                      _acknowledgedBatchOutputs = null;
                    });
                    controller.retryBatch();
                  },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry unfinished files'),
          ),
        if (withOutput.any(
          (session) => session.processing!.integrity.needsAcknowledgment,
        ))
          CheckboxListTile(
            key: const Key('acknowledgeBatchExport'),
            value: _acknowledgeBatchExport,
            onChanged: controller.busy
                ? null
                : (value) => setState(() {
                    _acknowledgeBatchExport = value ?? false;
                    _acknowledgedBatchOutputs = _acknowledgeBatchExport
                        ? _batchOutputSignature()
                        : null;
                  }),
            title: const Text('Accept the listed limitations for ready copies'),
            subtitle: const Text(
              'Review each copy’s checks and limitations in Details before exporting.',
            ),
          ),
      ],
    );
  }

  Widget _minimalEditContent(BuildContext context) {
    final controller = widget.controller;
    final sources = widget.batch
        ? controller.sessions
              .where((s) => controller.batchSelection.contains(s.id))
              .toList()
        : [widget.session];
    final colors = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.batch)
          Row(
            children: [
              for (final item in sources.take(3))
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: MediaPreview(session: item, height: 120),
                  ),
                ),
            ],
          )
        else
          MediaPreview(session: widget.session, height: 200),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.batch
                        ? '${sources.length} files selected'
                        : widget.session.displayName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    widget.batch
                        ? 'One shared metadata plan'
                        : '${widget.session.inspection.kind.label} · ${widget.session.inspection.sizeLabel}',
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => _showSelectionInfo(context, sources),
              child: Text(widget.batch ? 'Change selection' : 'Change'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                key: const Key('chooseHostProfile'),
                leading: const Icon(Icons.phone_iphone),
                title: const Text('Your phone'),
                subtitle: Text(
                  profile == null
                      ? 'Choose a supported phone profile'
                      : '${profile!.brand} · ${profile!.model}${_autoMatched ? '\nAuto-matched' : ''}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: controller.busy || _preparingDraft
                    ? null
                    : () async {
                        final profiles = await catalog;
                        if (mounted && context.mounted) {
                          _openModelSearchSheet(context, profiles);
                        }
                      },
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                key: const Key('chooseMainCamera'),
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Camera'),
                subtitle: Text(camera?.name ?? 'Choose a model first'),
                trailing: const Icon(Icons.chevron_right),
                onTap: controller.busy || profile == null
                    ? null
                    : () => _openCameraPickerSheet(context, profile!.cameras),
              ),
              if (supported.contains('latitude') &&
                  supported.contains('longitude')) ...[
                const Divider(height: 1, indent: 56),
                ListTile(
                  key: const Key('pickLocationMap'),
                  leading: const Icon(Icons.place_outlined),
                  title: const Text('Location'),
                  subtitle: Text(
                    _hasTimedMetadata
                        ? 'Disabled: continuous GPS track present'
                        : modes['latitude'] == 'set' &&
                              modes['longitude'] == 'set'
                        ? '${inputs['latitude']!.text}, ${inputs['longitude']!.text}'
                        : 'Choose on map',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _hasTimedMetadata
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: controller.busy || _preparingDraft || _hasTimedMetadata
                      ? null
                      : _selectLocationOnMap,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: ExpansionTile(
            key: const Key('manualEditing'),
            maintainState: true,
            leading: const Icon(Icons.tune_rounded),
            title: const Text('Manual editing'),
            subtitle: const Text('Adjust the prepared changes'),
            enabled: !_preparingDraft,
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              _presets(context),
              const SizedBox(height: 12),
              _manual(context),
              if (widget.batch) _batchTimestampControl(),
              ListTile(
                key: const Key('privacyScrubFromManual'),
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove selected metadata'),
                trailing: const Icon(Icons.chevron_right),
                onTap: controller.busy
                    ? null
                    : () => _openQuickPrivacyScrubber(context),
              ),
              _metadataDetails(context),
              if (!widget.batch && widget.session.processing != null)
                ListTile(
                  key: const Key('viewExistingCopy'),
                  leading: const Icon(Icons.file_present_outlined),
                  title: const Text('View saved copy'),
                  onTap: controller.busy
                      ? null
                      : () => setState(() {
                          _viewingExistingCopy = true;
                          _processingIdsBefore = {widget.session.id: null};
                          _stage = _FormStage.result;
                        }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_preparingDraft)
          const LinearProgressIndicator()
        else
          Text(
            widget.batch
                ? 'The same randomized metadata is prepared for all ${sources.length} files. Each copy gets a unique IMG_#### filename.'
                : 'Randomized changes are ready to review.',
            style: TextStyle(color: colors.muted, fontSize: 12, height: 1.5),
          ),
        if (profile == null && !_preparingDraft)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'This phone could not be matched. Choose a profile, or use Manual editing.',
              style: TextStyle(color: colors.muted),
            ),
          ),
        if (formError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(formError!, style: TextStyle(color: colors.error)),
          ),
      ],
    );
  }

  void _showSelectionInfo(BuildContext context, List<MediaSession> sources) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Selected files')),
            for (final source in sources)
              ListTile(
                title: Text(source.displayName),
                subtitle: Text(source.inspection.kind.label),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from Photos'),
              onTap: () {
                Navigator.of(context).pop();
                widget.controller.importBatch(photos: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Choose from Files'),
              onTap: () {
                Navigator.of(context).pop();
                widget.controller.importBatch(photos: false);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _batchTimestampControl() => ListTile(
    title: const Text('Timestamp spacing'),
    subtitle: const Text('Off keeps the same timestamps across the batch'),
    trailing: DropdownButton<int>(
      key: const Key('batchTimestampStagger'),
      value: _batchStaggerSeconds,
      onChanged: widget.controller.busy
          ? null
          : (value) => setState(() => _batchStaggerSeconds = value ?? 0),
      items: [
        for (final seconds in [0, 1, 5, 10, 30, 60])
          DropdownMenuItem(
            value: seconds,
            child: Text(seconds == 0 ? 'Off' : '+${seconds}s'),
          ),
      ],
    ),
  );

  void _showSavingGuide() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: WorkflowNote(),
      ),
    ),
  );

  Widget _stageContent(BuildContext context) {
    if (_stage == _FormStage.review && _reviewedPatches != null) {
      return _reviewContent(context);
    }
    if (_stage == _FormStage.result) return _resultContent(context);
    if (widget.fillAvailableSpace) return _minimalEditContent(context);
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
            style: TextStyle(
              color: AppTheme.of(context).accent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.of(context).surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.of(context).border),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_motion_outlined,
                  color: AppTheme.of(context).accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Selected files: ${controller.sessions.where((s) => controller.batchSelection.contains(s.id)).map((s) => s.displayName).take(3).join(', ')}${controller.batchSelection.length > 3 ? ' +${controller.batchSelection.length - 3} more' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.of(context).muted,
                    ),
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
              color: AppTheme.of(context).surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.of(context).border),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  color: AppTheme.of(context).accent,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Timestamp Spacing',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.of(context).text,
                    ),
                  ),
                ),
                DropdownButton<int>(
                  key: const Key('batchTimestampStagger'),
                  value: _batchStaggerSeconds,
                  dropdownColor: AppTheme.of(context).surface,
                  underline: const SizedBox(),
                  style: TextStyle(
                    color: AppTheme.of(context).accent,
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
            style: TextStyle(color: AppTheme.of(context).muted),
          ),
          const SizedBox(height: 12),
          if (!widget.fillAvailableSpace)
            _buildMediaInspectorHUD(context, source),
        ],
        if (formError != null)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.of(context).errorSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.of(context).errorBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: AppTheme.of(context).error,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Attention Needed',
                        style: TextStyle(
                          color: AppTheme.of(context).error,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        simplifyUserError(formError!),
                        style: TextStyle(
                          color: AppTheme.of(context).error,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: AppTheme.of(context).error,
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
        if (widget.fillAvailableSpace) ...[
          ExpansionTile(
            key: const Key('profilesAndPresets'),
            title: const Text('Profiles & presets'),
            subtitle: const Text('Optional camera profile and saved recipes'),
            children: [_presets(context)],
          ),
          _manual(context),
        ] else ...[
          TabBar(
            controller: _tabController,
            onTap: (index) {
              if (_tabIndex != index) {
                setState(() => _tabIndex = index);
              }
            },
            indicatorColor: AppTheme.of(context).accent,
            labelColor: AppTheme.of(context).accent,
            unselectedLabelColor: AppTheme.of(context).muted,
            tabs: const [
              Tab(text: 'Profile & presets'),
              Tab(text: 'Edit'),
            ],
          ),
          const SizedBox(height: 16),
          _tabIndex == 0 ? _presets(context) : _manual(context),
        ],
        const SizedBox(height: 16),
        if (!widget.fillAvailableSpace)
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
        if (!widget.batch && output != null && !widget.fillAvailableSpace)
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

  Widget _metadataDetails(BuildContext context) {
    final controller = widget.controller;
    final source = widget.session;
    final output = source.processing;
    return ExpansionTile(
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
            Padding(padding: const EdgeInsets.all(8), child: Text(limitation)),
          TextButton(
            onPressed: controller.busy ? null : controller.verifyOriginal,
            child: const Text('Verify downloaded iCloud original'),
          ),
        ],
        if (profile != null && camera != null) ...[
          const ListTile(title: Text('Camera profile evidence')),
          for (final e in camera!.evidence.entries)
            ListTile(dense: true, title: Text(e.key), subtitle: Text(e.value)),
          for (final url in profile!.sources)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(url),
            ),
        ],
      ],
    );
  }

  Widget _presets(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExpansionTile(
        key: const Key('profileSettingsExpansion'),
        initiallyExpanded: !widget.fillAvailableSpace,
        title: const Text('Camera profile & randomization'),
        subtitle: Text(
          profile == null
              ? 'Choose a researched device profile'
              : '${profile!.model} · ${camera?.name ?? 'Select camera'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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
              final brands = profiles.map((p) => p.brand).toSet().toList()
                ..sort();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Device Profile',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.of(context).muted,
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
                          foregroundColor: AppTheme.of(context).accent,
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
                    onTap: () => _openBrandPickerSheet(
                      context,
                      brands,
                      profiles: profiles,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildSelectorField(
                    key: ValueKey('model-${brand ?? "none"}'),
                    label: 'Model',
                    value:
                        profile?.model ??
                        (brand == null
                            ? 'Choose a brand first'
                            : 'Select model'),
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
                            icon: Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: AppTheme.of(context).accent,
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
                              ? AppTheme.of(context).accent
                              : AppTheme.of(context).subtle,
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
                        : () =>
                              _openCameraPickerSheet(context, profile!.cameras),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('applyProfile'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _appliedFeedback
                          ? AppTheme.of(context).border
                          : AppTheme.of(context).surface,
                      foregroundColor: _appliedFeedback
                          ? AppTheme.of(context).accent
                          : AppTheme.of(context).text,
                    ),
                    onPressed:
                        profile == null ||
                            camera == null ||
                            widget.controller.busy
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
                              _appliedTimer = Timer(
                                const Duration(seconds: 2),
                                () {
                                  if (mounted) {
                                    setState(() => _appliedFeedback = false);
                                  }
                                },
                              );
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
                        : Text(
                            widget.fillAvailableSpace
                                ? 'Apply camera profile'
                                : 'Apply & randomize',
                          ),
                  ),
                  if (_appliedFeedback) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.of(context).surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppTheme.of(context).success
                              .withValues(alpha: 0.12),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 16,
                            color: AppTheme.of(context).success,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.fillAvailableSpace
                                  ? 'Profile values staged. Review changes before creating a copy.'
                                  : 'Settings applied. Press "Process" below to generate your file.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppTheme.of(context).success,
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
                    Text(
                      'Lens label is descriptive; exact capture wording has not been verified.',
                      style: TextStyle(
                        color: AppTheme.of(context).muted,
                        fontSize: 12,
                      ),
                    ),
                  Text(
                    '${profiles.length} researched models. Unknown hardware fields are cleared rather than invented.',
                    style: TextStyle(
                      color: AppTheme.of(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      const SizedBox(height: 20),
      const Text('Saved presets'),
      const SizedBox(height: 10),
      if (widget.controller.presets.isEmpty)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.of(context).surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.of(context).border),
          ),
          child: Center(
            child: Text(
              'No saved presets. Save current edits or import a recipe.',
              style: TextStyle(color: AppTheme.of(context).muted, fontSize: 13),
            ),
          ),
        )
      else
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.of(context).border),
          ),
          child: Material(
            color: AppTheme.of(context).surface,
            child: Column(
              children: [
                for (var i = 0; i < widget.controller.presets.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppTheme.of(context).border,
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
                            ? AppTheme.of(context).border
                            : AppTheme.of(context).accent
                                  .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        widget.controller.presets[i].recipe == null
                            ? Icons.tune_rounded
                            : Icons.auto_awesome_rounded,
                        size: 16,
                        color: widget.controller.presets[i].recipe == null
                            ? AppTheme.of(context).muted
                            : AppTheme.of(context).accent,
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
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.of(context).muted,
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
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'export',
                          child: Text('Export preset'),
                        ),
                        const PopupMenuItem(
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
      const SizedBox(height: 8),
      ExpansionTile(
        key: const Key('advancedPresetActions'),
        initiallyExpanded: !widget.fillAvailableSpace,
        title: const Text('Advanced preset tools'),
        subtitle: const Text('Save edits or import a preset recipe'),
        children: [
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
      ),
    ],
  );
  Widget _profileSummary(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppTheme.of(context).surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.of(context).border),
    ),
    child: Row(
      children: [
        Icon(Icons.camera_alt_outlined, color: AppTheme.of(context).accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Camera profile',
                style: TextStyle(
                  color: AppTheme.of(context).muted,
                  fontSize: 12,
                ),
              ),
              Text(
                profile == null
                    ? 'No profile selected'
                    : '${profile!.model} · ${camera?.name ?? 'Select camera'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('configureProfileFromEdit'),
          tooltip: 'Choose camera profile',
          onPressed: widget.controller.busy
              ? null
              : () async {
                  final profiles = await catalog;
                  if (mounted && context.mounted) {
                    _openModelSearchSheet(context, profiles);
                  }
                },
          icon: const Icon(Icons.search_rounded),
        ),
        IconButton(
          key: const Key('configureRandomizationFromEdit'),
          tooltip: 'Randomization settings',
          onPressed: widget.controller.busy ? null : _configureRandomization,
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    ),
  );

  Widget _manual(BuildContext context) {
    final groups = metadataFields
        .where((f) => supported.contains(f.key))
        .map((f) => f.group)
        .toSet();
    return Column(
      children: [
        _profileSummary(context),
        if (widget.fillAvailableSpace) ...[
          _automaticDates(),
          const SizedBox(height: 12),
          if (supported.contains('software'))
            SwitchListTile(
              key: const Key('quickRemoveSoftware'),
              contentPadding: EdgeInsets.zero,
              value: modes['software'] == 'remove',
              onChanged: widget.controller.busy
                  ? null
                  : (remove) => setState(() {
                      modes['software'] = remove ? 'remove' : 'keep';
                      explicitOverrides.add('software');
                    }),
              title: const Text('Remove software tag'),
              subtitle: Text(switch (modes['software']) {
                'remove' => 'Current plan removes the original software tag.',
                'set' =>
                  'Current plan sets “${inputs['software']!.text}”; turning this on removes it.',
                _ => 'Current plan keeps the original value unchanged.',
              }),
            ),
        ],
        Text(
          'Keep retains the original. Set changes a value. Remove deletes the selected field.',
          style: TextStyle(color: AppTheme.of(context).muted, fontSize: 12),
        ),
        if (widget.fillAvailableSpace)
          ExpansionTile(
            key: const Key('advancedMetadata'),
            title: const Text('Advanced metadata'),
            subtitle: const Text(
              'Camera, exposure, location, and individual fields',
            ),
            children: [for (final group in groups) _metadataGroup(group)],
          )
        else
          for (final group in groups) _metadataGroup(group),
        if (groups.isEmpty)
          const Text(
            'This format currently has no supported metadata operations.',
          ),
      ],
    );
  }

  Widget _metadataGroup(String group) => ExpansionTile(
    initiallyExpanded: group == 'Camera',
    title: Text(group),
    children: [
      if (!widget.fillAvailableSpace &&
          (group == 'Dates' || group == 'Video dates'))
        _automaticDates(),
      if (!widget.fillAvailableSpace && group == 'Location')
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: OutlinedButton.icon(
            key: const Key('pickLocationMap'),
            onPressed: widget.controller.busy ? null : _selectLocationOnMap,
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
                    items: [
                      const DropdownMenuItem(
                        value: 'keep',
                        child: Text('Keep'),
                      ),
                      const DropdownMenuItem(value: 'set', child: Text('Set')),
                      DropdownMenuItem(
                        value: 'remove',
                        enabled: !_hasCompetingMetadata,
                        child: Text(
                          _hasCompetingMetadata
                              ? 'Remove (XMP restricted)'
                              : 'Remove',
                        ),
                      ),
                    ],
                    onChanged: widget.controller.busy
                        ? null
                        : (mode) => setState(() {
                            if (_dateFieldKeys.contains(field.key)) {
                              _quickDateSelected = false;
                            }
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
                    key: Key(field.key == 'lensModel' ? 'lens' : field.key),
                    controller: inputs[field.key],
                    onChanged: (_) {
                      if (_dateFieldKeys.contains(field.key)) {
                        _quickDateSelected = false;
                      }
                      explicitOverrides.add(field.key);
                    },
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
  );

  Future<void> _loadPreset(SavedPreset preset) async {
    try {
      if (preset.recipe == null) {
        settings = settings.withAutomaticDates(false);
        _quickDateSelected = false;
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
                      style: TextStyle(color: AppTheme.of(context).error),
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
        color: AppTheme.of(context).surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.of(context).border),
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
                color: AppTheme.of(context).accent,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cameraName.isNotEmpty
                      ? cameraName
                      : 'Original Hardware Unspecified',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.of(context).text,
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
                  side: BorderSide(color: AppTheme.of(context).border),
                ),
              ),
            ],
          ),
          if (lens != null && lens.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              lens,
              style: TextStyle(fontSize: 11, color: AppTheme.of(context).muted),
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
                      ? AppTheme.of(context).surface
                      : AppTheme.of(context).raised,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: hasGps
                        ? AppTheme.of(context).success.withValues(alpha: 0.12)
                        : AppTheme.of(context).border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasGps ? Icons.location_on : Icons.location_off_outlined,
                      size: 12,
                      color: hasGps
                          ? AppTheme.of(context).success
                          : AppTheme.of(context).muted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      hasGps ? 'GPS Tagged' : 'No Geotag',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: hasGps
                            ? AppTheme.of(context).success
                            : AppTheme.of(context).muted,
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
        color: AppTheme.of(context).raised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.of(context).border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: active
              ? AppTheme.of(context).text
              : AppTheme.of(context).muted,
        ),
      ),
    );
  }

  Future<void> _openQuickPrivacyScrubber(BuildContext context) async {
    final scrubbed = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.of(context).raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _QuickPrivacyScrubberSheet(
        supportedFields: supported,
        hasCompeting: _hasCompetingMetadata,
        hasTimedMetadata: _hasTimedMetadata,
      ),
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
              'Removal prepared for ${scrubbed.length} fields. Review the changes before creating a copy.',
            ),
            backgroundColor: AppTheme.of(this.context).surface,
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
        border: Border.all(color: AppTheme.of(context).border),
      ),
      child: Material(
        color: AppTheme.of(context).raised,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('metadataDiffTile'),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            title: Row(
              children: [
                Icon(
                  Icons.compare_arrows_rounded,
                  color: AppTheme.of(context).accent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Metadata Diff (Before vs After)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.of(context).text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            subtitle: Text(
              '${changed.length} changed · ${removals.length} removed · ${preserved.length} preserved',
              style: TextStyle(fontSize: 11, color: AppTheme.of(context).muted),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Divider(color: AppTheme.of(context).border, height: 1),
                    const SizedBox(height: 8),
                    if (changed.isNotEmpty) ...[
                      Text(
                        'CHANGED / ADDED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppTheme.of(context).accent,
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
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.of(context).muted,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${entry.value.$1}  ➔  ${entry.value.$2}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: AppTheme.of(context).success,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                    if (removals.isNotEmpty) ...[
                      Text(
                        'REMOVED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppTheme.of(context).error,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final key in removals)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.remove_circle_outline,
                                size: 12,
                                color: AppTheme.of(context).error,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                key,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.of(context).error,
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
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppTheme.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preserved.join(', '),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.of(context).muted,
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
                  color: AppTheme.of(context).border,
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
                                color: AppTheme.of(context).text,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$brandName catalog · ${widget.availableProfiles.length} profiles',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.of(context).muted,
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
                          decoration: BoxDecoration(
                            color: AppTheme.of(context).border,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: AppTheme.of(context).muted,
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
                  color: AppTheme.of(context).surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.of(context).border),
                ),
                child: TextField(
                  controller: _searchController,
                  autofocus: false,
                  textAlignVertical: TextAlignVertical.center,
                  cursorColor: AppTheme.of(context).accent,
                  cursorWidth: 1.5,
                  cursorHeight: 16,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.of(context).text,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search $brandName models…',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: AppTheme.of(context).subtle,
                    ),
                    filled: false,
                    fillColor: Colors.transparent,
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 38,
                    ),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 10, right: 6),
                      child: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: AppTheme.of(context).accent,
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
                            icon: Icon(
                              Icons.clear_rounded,
                              size: 16,
                              color: AppTheme.of(context).muted,
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
                    color: AppTheme.of(context).surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.of(context).border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search_off_rounded,
                                  size: 32,
                                  color: AppTheme.of(context).subtle,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No matching models found.',
                                  style: TextStyle(
                                    color: AppTheme.of(context).muted,
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
                          separatorBuilder: (context, index) => Divider(
                            height: 1,
                            thickness: 1,
                            indent: 16,
                            endIndent: 16,
                            color: AppTheme.of(context).border,
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
                                    ? AppTheme.of(context).border
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
                                                  ? AppTheme.of(context).accent
                                                  : AppTheme.of(context).text,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${p.brand} · $cameraSummary',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: AppTheme.of(context).muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isSelected)
                                      Container(
                                        width: 20,
                                        height: 20,
                                        decoration: BoxDecoration(
                                          color: AppTheme.of(context).accent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.check_rounded,
                                          size: 13,
                                          color: AppTheme.of(context).text,
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
                color: AppTheme.of(context).border,
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
                              color: AppTheme.of(context).text,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${brands.length} camera manufacturers available',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.of(context).muted,
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
                        decoration: BoxDecoration(
                          color: AppTheme.of(context).border,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: AppTheme.of(context).muted,
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
                  color: AppTheme.of(context).surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.of(context).border),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: brands.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    thickness: 1,
                    indent: 56,
                    endIndent: 16,
                    color: AppTheme.of(context).border,
                  ),
                  itemBuilder: (context, index) {
                    final b = brands[index];
                    final isSelected = selectedBrand == b;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(b),
                      child: Container(
                        color: isSelected
                            ? AppTheme.of(context).border
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
                                color: AppTheme.of(context).border,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                _brandGlyph(b),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.of(context).text,
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
                                          ? AppTheme.of(context).accent
                                          : AppTheme.of(context).text,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    _brandSubtitle(b),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.of(context).muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: AppTheme.of(context).accent,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: AppTheme.of(context).text,
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
                color: AppTheme.of(context).border,
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
                              color: AppTheme.of(context).text,
                            ),
                      ),
                      if (profileModel != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              profileModel!,
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.of(context).muted,
                              ),
                            ),
                            Text(
                              ' · $lensSummary',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.of(context).muted,
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
                        decoration: BoxDecoration(
                          color: AppTheme.of(context).border,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: AppTheme.of(context).muted,
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
                  color: AppTheme.of(context).surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.of(context).border),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: cameras.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    thickness: 1,
                    indent: 16,
                    endIndent: 16,
                    color: AppTheme.of(context).border,
                  ),
                  itemBuilder: (context, index) {
                    final c = cameras[index];
                    final isSelected = selectedCameraId == c.id;
                    final subtitle = _cameraSubtitle(c);
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(c),
                      child: Container(
                        color: isSelected
                            ? AppTheme.of(context).border
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
                                          ? AppTheme.of(context).accent
                                          : AppTheme.of(context).text,
                                    ),
                                  ),
                                  if (subtitle != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.of(context).muted,
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
                                decoration: BoxDecoration(
                                  color: AppTheme.of(context).accent,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.check_rounded,
                                  size: 13,
                                  color: AppTheme.of(context).text,
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
  const _QuickPrivacyScrubberSheet({
    required this.supportedFields,
    this.hasCompeting = false,
    this.hasTimedMetadata = false,
  });
  final Set<String> supportedFields;
  final bool hasCompeting;
  final bool hasTimedMetadata;

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
    if (widget.hasCompeting) return const {};
    final fields = <String>{};
    if (_stripLocation && !widget.hasTimedMetadata) {
      fields.addAll(_locationFields);
    }
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
                  color: AppTheme.of(context).border,
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
                      color: AppTheme.of(context).accent
                          .withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.shield_outlined,
                      color: AppTheme.of(context).accent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quick Privacy Scrubber',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: AppTheme.of(context).text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Select categories to strip before sharing',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.of(context).muted,
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
                        decoration: BoxDecoration(
                          color: AppTheme.of(context).border,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: AppTheme.of(context).muted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (widget.hasCompeting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.of(context).surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.of(context).border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 20,
                        color: AppTheme.of(context).accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Adobe XMP / Photoshop data present. Field removal is restricted by container rules to prevent duplicate unscrubbed tags. Overwrite values using Manual Editing instead.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.of(context).muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.of(context).surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.of(context).border),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _buildToggleRow(
                      icon: Icons.location_off_outlined,
                      title: 'Location & GPS Geotags',
                      subtitle: widget.hasTimedMetadata
                          ? 'Disabled: continuous GPS track present'
                          : 'Latitude, longitude, altitude coordinates',
                      value: widget.hasTimedMetadata ? false : _stripLocation,
                      onChanged: widget.hasTimedMetadata
                          ? (_) {}
                          : (v) => setState(() => _stripLocation = v),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppTheme.of(context).border,
                      indent: 52,
                    ),
                    _buildToggleRow(
                      icon: Icons.perm_device_information_outlined,
                      title: 'Hardware & Device Identifiers',
                      subtitle: 'Camera/lens serial numbers, owner name, host',
                      value: _stripHardware,
                      onChanged: (v) => setState(() => _stripHardware = v),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppTheme.of(context).border,
                      indent: 52,
                    ),
                    _buildToggleRow(
                      icon: Icons.person_outline_rounded,
                      title: 'Author & Copyright Data',
                      subtitle: 'Artist, copyright text, user comments',
                      value: _stripAuthor,
                      onChanged: (v) => setState(() => _stripAuthor = v),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: AppTheme.of(context).border,
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
      activeTrackColor: AppTheme.of(context).accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: value
              ? AppTheme.of(context).accent.withValues(alpha: 0.10)
              : AppTheme.of(context).border,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 16,
          color: value
              ? AppTheme.of(context).accent
              : AppTheme.of(context).muted,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppTheme.of(context).text,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11, color: AppTheme.of(context).muted),
      ),
    );
  }
}
