import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'media_models.dart';
import 'metadata_patch.dart';

class CameraProfile {
  CameraProfile(
    this.id,
    this.brand,
    this.model,
    this.make,
    this.lensMake,
    this.cameras,
    this.sources,
    this.randomization, {
    this.clearFields = const {},
  });
  final String id, brand, model, make, lensMake;
  final List<ProfileCamera> cameras;
  final List<String> sources;
  final Map<String, Object?> randomization;
  final Set<String> clearFields;
  factory CameraProfile.decode(Object? raw) {
    final m = objectMap(raw);
    final cameras = m['cameras'];
    if (cameras is! List || cameras.isEmpty) {
      throw const FormatException('No cameras in profile.');
    }
    return CameraProfile(
      requiredString(m, 'id'),
      requiredString(m, 'brand'),
      requiredString(m, 'model'),
      requiredString(m, 'make'),
      requiredString(m, 'lensMake'),
      cameras.map(ProfileCamera.decode).toList(),
      strings(m['sources']),
      objectMap(m['randomization']),
      clearFields: strings(m['clearFields'] ?? <String>[]).toSet(),
    );
  }
}

class ProfileCamera {
  ProfileCamera(
    this.id,
    this.name,
    this.fields,
    this.evidence, {
    this.clearFields = const {},
  });
  final String id, name;
  final Map<String, Object> fields;
  final Map<String, String> evidence;
  final Set<String> clearFields;
  factory ProfileCamera.decode(Object? raw) {
    final m = objectMap(raw);
    final fields = objectMap(m['fields']);
    if (fields.values.any((v) => v is! String && v is! num && v is! bool)) {
      throw const FormatException('Invalid camera fields.');
    }
    return ProfileCamera(
      requiredString(m, 'id'),
      requiredString(m, 'name'),
      fields.map((k, v) => MapEntry(k, v as Object)),
      stringMap(m['fieldEvidence']),
      clearFields: strings(m['clearFields'] ?? <String>[]).toSet(),
    );
  }
}

Future<List<CameraProfile>>? _cachedCatalog;
List<CameraProfile>? _loadedCatalog;
Future<List<CameraProfile>> loadCameraProfiles() => _loadedCatalog != null
    ? SynchronousFuture(_loadedCatalog!)
    : (_cachedCatalog ??= _readCameraProfiles());
Future<List<CameraProfile>> _readCameraProfiles() async {
  final m = objectMap(
    jsonDecode(await rootBundle.loadString('assets/camera_profiles.json')),
  );
  if (m['schemaVersion'] != 1 || m['profiles'] is! List) {
    throw const FormatException('Incompatible camera catalog.');
  }
  final profiles = (m['profiles'] as List).map(CameraProfile.decode).toList();
  if (profiles.map((p) => p.id).toSet().length != profiles.length) {
    throw const FormatException('Duplicate camera profiles.');
  }
  _loadedCatalog = List.unmodifiable(profiles);
  return _loadedCatalog!;
}

class RandomizationSettings {
  const RandomizationSettings({
    this.isoMin = 40,
    this.isoMax = 1000,
    this.pastDays = 365,
    this.shutters = const [
      1 / 24,
      1 / 30,
      1 / 60,
      1 / 120,
      1 / 240,
      1 / 500,
      1 / 1000,
    ],
    this.randomizeExposure = true,
    this.randomizeDates = true,
    this.randomizeSoftware = true,
    this.latitude,
    this.longitude,
    this.altitude,
    this.locationRadiusMeters = 50,
  });
  final int isoMin, isoMax, pastDays;
  final List<double> shutters;
  final bool randomizeExposure, randomizeDates, randomizeSoftware;
  final double? latitude, longitude, altitude;
  final double locationRadiusMeters;
  String? validate() {
    if (isoMin < 1 ||
        isoMax > 65535 ||
        isoMax < isoMin ||
        pastDays < 0 ||
        pastDays > 36500 ||
        shutters.isEmpty ||
        shutters.any((s) => !s.isFinite || s <= 0 || s > 86400)) {
      return 'Check the ISO, shutter and date ranges.';
    }
    if ((latitude == null) != (longitude == null) ||
        (latitude != null &&
            (!latitude!.isFinite ||
                latitude!.abs() > 90 ||
                !longitude!.isFinite ||
                longitude!.abs() > 180)) ||
        !locationRadiusMeters.isFinite ||
        locationRadiusMeters < 0 ||
        locationRadiusMeters > 100000 ||
        (altitude != null && !altitude!.isFinite)) {
      return 'Check the location and radius.';
    }
    return null;
  }

  RandomizationSettings withAutomaticDates(bool enabled) =>
      RandomizationSettings.decode({...toMap(), 'randomizeDates': enabled});
  Map<String, Object?> toMap() => {
    'isoMin': isoMin,
    'isoMax': isoMax,
    'pastDays': pastDays,
    'shutters': shutters,
    'randomizeExposure': randomizeExposure,
    'randomizeDates': randomizeDates,
    'randomizeSoftware': randomizeSoftware,
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'locationRadiusMeters': locationRadiusMeters,
  };
  factory RandomizationSettings.decode(Object? raw) {
    final m = objectMap(raw);
    num number(String key) {
      final value = m[key];
      if (value is! num || !value.isFinite) {
        throw const FormatException('Invalid randomization number.');
      }
      return value;
    }

    int integer(String key) {
      final v = number(key);
      if (v != v.roundToDouble()) {
        throw const FormatException('Invalid integer.');
      }
      return v.toInt();
    }

    bool flag(String key) {
      final value = m[key];
      if (value is! bool) {
        throw const FormatException('Invalid randomization option.');
      }
      return value;
    }

    double? optional(String key) =>
        m[key] == null ? null : number(key).toDouble();
    final shutters = m['shutters'];
    if (shutters is! List ||
        shutters.length > 100 ||
        shutters.any((v) => v is! num)) {
      throw const FormatException('Invalid shutter choices.');
    }
    final settings = RandomizationSettings(
      isoMin: integer('isoMin'),
      isoMax: integer('isoMax'),
      pastDays: integer('pastDays'),
      shutters: shutters.cast<num>().map((v) => v.toDouble()).toList(),
      randomizeExposure: flag('randomizeExposure'),
      randomizeDates: flag('randomizeDates'),
      randomizeSoftware: flag('randomizeSoftware'),
      latitude: optional('latitude'),
      longitude: optional('longitude'),
      altitude: optional('altitude'),
      locationRadiusMeters: number('locationRadiusMeters').toDouble(),
    );
    final invalid = settings.validate();
    if (invalid != null) throw FormatException(invalid);
    return settings;
  }
  MetadataPatch generate(
    CameraProfile profile,
    ProfileCamera camera,
    MediaKind kind,
    Random random,
    DateTime now, {
    Set<String>? supportedFields,
  }) {
    final invalid = validate();
    if (invalid != null) throw FormatException(invalid);
    final values = <String, Object>{
      'make': profile.make,
      'model': profile.model,
      'lensMake': profile.lensMake,
      ...camera.fields,
    };
    if (profile.brand == 'Apple') values['hostComputer'] = 'iPhone';
    if (randomizeExposure) {
      values.addAll({
        'iso': isoMin + random.nextInt(isoMax - isoMin + 1),
        'exposureTime': shutters[random.nextInt(shutters.length)],
        'exposureCompensation': 0,
        'meteringMode': 5,
        'flash': 16,
      });
    }
    if (randomizeSoftware) {
      final versions = profile.randomization['software'];
      if (versions is List && versions.isNotEmpty) {
        values['software'] =
            versions[random.nextInt(versions.length)] as String;
      }
    }
    if (randomizeDates) {
      final date = now.subtract(
        Duration(seconds: random.nextInt(max(1, pastDays * 86400 + 1))),
      );
      String two(int v) => v.toString().padLeft(2, '0');
      final dateText =
          '${date.year}:${two(date.month)}:${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
      final offset = date.timeZoneOffset;
      final minutes = offset.inMinutes.abs();
      final offsetText =
          '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}:${two(minutes % 60)}';
      if (kind.isImage) {
        values.addAll({
          'dateTimeOriginal': dateText,
          'createDate': dateText,
          'modifyDate': dateText,
          'offsetTime': offsetText,
          'offsetTimeOriginal': offsetText,
          'offsetTimeDigitized': offsetText,
        });
      } else {
        for (final key in [
          'dateTimeOriginal',
          'createDate',
          'modifyDate',
          'movieCreateDate',
          'movieModifyDate',
          'trackCreateDate',
          'trackModifyDate',
          'mediaCreateDate',
          'mediaModifyDate',
        ]) {
          values[key] = date.toUtc().toIso8601String();
        }
      }
    }
    if (latitude != null && longitude != null) {
      final distance = sqrt(random.nextDouble()) * locationRadiusMeters;
      final angle = random.nextDouble() * 2 * pi;
      final lat = (latitude! + cos(angle) * distance / 111320).clamp(
        -90.0,
        90.0,
      );
      final lon =
          longitude! +
          sin(angle) *
              distance /
              max(1, 111320 * cos(latitude! * pi / 180).abs());
      values.addAll({'latitude': lat, 'longitude': ((lon + 180) % 360) - 180});
      if (altitude != null) {
        values['altitude'] = altitude! + (random.nextDouble() * 10 - 5);
      }
      if (kind.isImage) {
        values['imageDirection'] = (random.nextDouble() * 360).clamp(
          0.0,
          359.999999,
        );
      }
    }
    if (supportedFields != null) {
      values.removeWhere((key, value) => !supportedFields.contains(key));
    }
    return MetadataPatch(values: values);
  }
}

class SavedPreset {
  SavedPreset(this.id, this.name, this.patch, {this.recipe});
  final String id, name;
  final MetadataPatch patch;
  final ProfileRecipe? recipe;
  Map<String, Object?> toMap() => {
    'schemaVersion': 1,
    'id': id,
    'name': name,
    'patch': patch.toMap(),
    if (recipe != null) 'recipe': recipe!.toMap(),
  };
  factory SavedPreset.decode(Object? raw) {
    final m = objectMap(raw);
    if (m['schemaVersion'] != 1) {
      throw const FormatException('Unsupported preset version.');
    }
    final name = requiredString(m, 'name');
    if (name.trim().isEmpty || name.length > 80) {
      throw const FormatException('Preset name must have 1–80 characters.');
    }
    return SavedPreset(
      identifier(m, 'id'),
      name,
      MetadataPatch.decode(m['patch']),
      recipe: m['recipe'] == null ? null : ProfileRecipe.decode(m['recipe']),
    );
  }
}

class ProfileRecipe {
  ProfileRecipe(
    this.profileId,
    this.cameraId,
    this.settings, {
    this.overrides,
    this.keepFields = const {},
  });
  final String profileId, cameraId;
  final RandomizationSettings settings;
  final MetadataPatch? overrides;
  final Set<String> keepFields;
  Map<String, Object?> toMap() => {
    'profileId': profileId,
    'cameraId': cameraId,
    'settings': settings.toMap(),
    'overrides': overrides?.toMap(),
    'keepFields': keepFields.toList(),
  };
  factory ProfileRecipe.decode(Object? raw) {
    final m = objectMap(raw);
    final profile = requiredString(m, 'profileId'),
        camera = requiredString(m, 'cameraId');
    if (profile.isEmpty ||
        profile.length > 120 ||
        camera.isEmpty ||
        camera.length > 120) {
      throw const FormatException('Invalid profile recipe.');
    }
    final keep = strings(m['keepFields']).toSet();
    if (keep.any((key) => !metadataFields.any((f) => f.key == key))) {
      throw const FormatException('Invalid kept recipe field.');
    }
    final overrides = m['overrides'] == null
        ? null
        : MetadataPatch.decode(m['overrides']);
    if (overrides != null &&
        keep.any(
          (key) =>
              overrides.values.containsKey(key) ||
              overrides.removals.contains(key),
        )) {
      throw const FormatException('Contradictory recipe fields.');
    }
    return ProfileRecipe(
      profile,
      camera,
      RandomizationSettings.decode(m['settings']),
      overrides: overrides,
      keepFields: keep,
    );
  }
}

MetadataPatch applyRecipeOverrides(
  MetadataPatch generated,
  ProfileRecipe recipe, {
  Set<String>? supportedFields,
}) {
  final values = {...generated.values};
  final removals = {...generated.removals};
  for (final key in recipe.keepFields) {
    values.remove(key);
    removals.remove(key);
  }
  for (final e
      in recipe.overrides?.values.entries ?? <MapEntry<String, Object>>[]) {
    if (supportedFields == null || supportedFields.contains(e.key)) {
      values[e.key] = e.value;
      removals.remove(e.key);
    }
  }
  for (final key in recipe.overrides?.removals ?? <String>{}) {
    if (supportedFields == null || supportedFields.contains(key)) {
      values.remove(key);
      removals.add(key);
    }
  }
  return MetadataPatch(values: values, removals: removals);
}
