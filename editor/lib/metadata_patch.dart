import 'dart:convert';

class MetadataField {
  const MetadataField(
    this.key,
    this.label,
    this.group, {
    this.numeric = false,
    this.video = false,
  });
  final String key, label, group;
  final bool numeric, video;
}

const metadataFields = <MetadataField>[
  MetadataField('make', 'Make', 'Camera'),
  MetadataField('model', 'Model', 'Camera'),
  MetadataField('lensMake', 'Lens make', 'Camera'),
  MetadataField('lensModel', 'Lens', 'Camera'),
  MetadataField('hostComputer', 'Host computer', 'Camera'),
  MetadataField('software', 'Software', 'Camera'),
  MetadataField('iso', 'ISO', 'Exposure', numeric: true),
  MetadataField(
    'exposureTime',
    'Shutter seconds (or 1/120)',
    'Exposure',
    numeric: true,
  ),
  MetadataField('fNumber', 'Aperture', 'Exposure', numeric: true),
  MetadataField(
    'exposureCompensation',
    'Exposure compensation',
    'Exposure',
    numeric: true,
  ),
  MetadataField('focalLength', 'Focal length (mm)', 'Exposure', numeric: true),
  MetadataField(
    'focalLength35mm',
    '35 mm equivalent (mm)',
    'Exposure',
    numeric: true,
  ),
  MetadataField(
    'meteringMode',
    'Metering mode (EXIF number)',
    'Exposure',
    numeric: true,
  ),
  MetadataField('flash', 'Flash (EXIF bitmask)', 'Exposure', numeric: true),
  MetadataField('dateTimeOriginal', 'Captured date', 'Dates'),
  MetadataField('createDate', 'Created date', 'Dates'),
  MetadataField('modifyDate', 'Modified date', 'Dates'),
  MetadataField('offsetTime', 'Time zone ±HH:MM', 'Dates'),
  MetadataField('offsetTimeOriginal', 'Captured time zone', 'Dates'),
  MetadataField('offsetTimeDigitized', 'Digitized time zone', 'Dates'),
  MetadataField(
    'movieCreateDate',
    'Movie created (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField(
    'movieModifyDate',
    'Movie modified (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField(
    'trackCreateDate',
    'Track created (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField(
    'trackModifyDate',
    'Track modified (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField(
    'mediaCreateDate',
    'Media created (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField(
    'mediaModifyDate',
    'Media modified (ISO 8601)',
    'Video dates',
    video: true,
  ),
  MetadataField('latitude', 'Latitude', 'Location', numeric: true),
  MetadataField('longitude', 'Longitude', 'Location', numeric: true),
  MetadataField('altitude', 'Altitude (m)', 'Location', numeric: true),
  MetadataField(
    'imageDirection',
    'Direction (degrees)',
    'Location',
    numeric: true,
  ),
  MetadataField('title', 'Title', 'Description'),
  MetadataField('description', 'Description', 'Description'),
  MetadataField('artist', 'Artist', 'Description'),
  MetadataField('copyright', 'Copyright', 'Description'),
  MetadataField('keywords', 'Keywords', 'Description'),
];

class MetadataPatch {
  MetadataPatch({
    Map<String, Object> values = const {},
    Iterable<String> removals = const [],
  }) : values = Map.unmodifiable(values),
       removals = Set<String>.unmodifiable(removals);
  final Map<String, Object> values;
  final Set<String> removals;
  Map<String, Object?> toMap() => {
    'values': values,
    'removals': removals.toList()..sort(),
  };
  factory MetadataPatch.decode(Object? raw) {
    if (raw is! Map || raw['values'] is! Map || raw['removals'] is! List) {
      throw const FormatException('Invalid metadata patch.');
    }
    final values = <String, Object>{};
    for (final entry in (raw['values'] as Map).entries) {
      if (entry.key is! String ||
          !(entry.value is String ||
              entry.value is num ||
              entry.value is bool)) {
        throw const FormatException('Invalid metadata value.');
      }
      values[entry.key as String] = entry.value as Object;
    }
    final removed = (raw['removals'] as List);
    if (removed.any((value) => value is! String)) {
      throw const FormatException('Invalid removal list.');
    }
    final patch = MetadataPatch(
      values: values,
      removals: removed.cast<String>(),
    );
    final invalid = patch.validate();
    if (invalid != null) throw FormatException(invalid);
    return patch;
  }
  String? validate() {
    final known = metadataFields.map((field) => field.key).toSet();
    if (values.isEmpty && removals.isEmpty) {
      return 'Choose at least one metadata change.';
    }
    if (values.keys.any((key) => !known.contains(key)) ||
        removals.any((key) => !known.contains(key))) {
      return 'Unsupported metadata field.';
    }
    if (values.keys.any(removals.contains)) {
      return 'A field cannot be changed and removed together.';
    }
    for (final entry in values.entries) {
      final field = metadataFields.firstWhere(
        (field) => field.key == entry.key,
      );
      if (field.numeric &&
          (entry.value is! num || !(entry.value as num).isFinite)) {
        return '${field.label} must be a finite number.';
      }
      if (!field.numeric &&
          (entry.value is! String ||
              (entry.value as String).trim().isEmpty ||
              utf8.encode(entry.value as String).length > 1024 ||
              (entry.value as String).runes.any(
                (rune) =>
                    (rune < 32 && rune != 10 && rune != 13 && rune != 9) ||
                    (rune >= 127 && rune <= 159),
              ))) {
        return '${field.label} needs readable text (up to 1024 bytes).';
      }
    }
    final bounds = <String, (double, double)>{
      'latitude': (-90, 90),
      'longitude': (-180, 180),
      'imageDirection': (0, 359.999999),
      'iso': (1, 65535),
      'fNumber': (0.01, 256),
      'exposureTime': (0.000000001, 86400),
      'focalLength': (0.01, 65535),
      'focalLength35mm': (1, 65535),
      'flash': (0, 127),
      'meteringMode': (0, 255),
    };
    for (final entry in bounds.entries) {
      final value = values[entry.key];
      if (value is num && (value < entry.value.$1 || value > entry.value.$2)) {
        return '${entry.key} is out of range.';
      }
    }
    for (final key in ['iso', 'flash', 'meteringMode', 'focalLength35mm']) {
      final value = values[key];
      if (value is num && value != value.roundToDouble()) {
        return '$key needs a whole number.';
      }
    }
    final direction = values['imageDirection'];
    if (direction is num && direction >= 360) {
      return 'Direction must be less than 360.';
    }
    final altitude = values['altitude'];
    if (altitude is num && altitude.abs() > 100000) {
      return 'Altitude is out of range.';
    }
    final ev = values['exposureCompensation'];
    if (ev is num && ev.abs() > 128) {
      return 'Exposure compensation is out of range.';
    }
    for (final key in [
      'offsetTime',
      'offsetTimeOriginal',
      'offsetTimeDigitized',
    ]) {
      final value = values[key];
      if (value != null &&
          !RegExp(r'^[+-](0\d|1[0-4]):[0-5]\d$').hasMatch(value.toString())) {
        return 'Time zones use ±HH:MM.';
      }
      if (value != null &&
          value.toString().substring(1, 3) == '14' &&
          !value.toString().endsWith(':00')) {
        return 'A 14-hour offset must use :00 minutes.';
      }
    }
    for (final key in ['dateTimeOriginal', 'createDate', 'modifyDate']) {
      final value = values[key];
      if (value != null) {
        final text = value.toString();
        final exif = RegExp(
          r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
        ).firstMatch(text);
        if (exif == null && !isStrictISODate(text)) {
          return 'Dates use YYYY:MM:DD HH:mm:ss for photos or ISO 8601 for videos.';
        }
        if (exif != null) {
          final parts = List<int>.generate(
            6,
            (i) => int.parse(exif.group(i + 1)!),
          );
          final d = DateTime.utc(
            parts[0],
            parts[1],
            parts[2],
            parts[3],
            parts[4],
            parts[5],
          );
          if (d.year != parts[0] ||
              d.month != parts[1] ||
              d.day != parts[2] ||
              d.hour != parts[3] ||
              d.minute != parts[4] ||
              d.second != parts[5]) {
            return 'The metadata date is invalid.';
          }
        }
      }
    }
    for (final key in [
      'movieCreateDate',
      'movieModifyDate',
      'trackCreateDate',
      'trackModifyDate',
      'mediaCreateDate',
      'mediaModifyDate',
    ]) {
      final value = values[key];
      if (value != null && !isStrictISODate(value.toString())) {
        return 'Video dates require ISO 8601.';
      }
    }
    return null;
  }

  bool equivalent(MetadataPatch other) =>
      values.length == other.values.length &&
      values.entries.every((e) {
        final otherVal = other.values[e.key];
        if (otherVal == e.value) return true;
        if (otherVal is num && e.value is num) {
          return (otherVal - (e.value as num)).abs() <= 1e-7;
        }
        return false;
      }) &&
      removals.length == other.removals.length &&
      removals.every(other.removals.contains);
  static Object parseField(MetadataField field, String text) {
    if (!field.numeric) return text.trim();
    final pieces = text.trim().split('/');
    final value = pieces.length == 2
        ? double.parse(pieces[0]) / double.parse(pieces[1])
        : double.parse(text);
    if (!value.isFinite) throw const FormatException('Invalid number.');
    return value;
  }
}

bool isStrictISODate(String text) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))$',
  ).firstMatch(text);
  if (match == null) return false;
  final parts = List.generate(6, (i) => int.parse(match.group(i + 1)!));
  final wall = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  return wall.year == parts[0] &&
      wall.month == parts[1] &&
      wall.day == parts[2] &&
      wall.hour == parts[3] &&
      wall.minute == parts[4] &&
      wall.second == parts[5] &&
      DateTime.tryParse(text) != null;
}
