import 'metadata_patch.dart';

const sharedDateOffsets = {
  'dateTimeOriginal': 'offsetTimeOriginal',
  'createDate': 'offsetTimeDigitized',
  'modifyDate': 'offsetTime',
};
const movieDateKeys = {
  'movieCreateDate',
  'movieModifyDate',
  'trackCreateDate',
  'trackModifyDate',
  'mediaCreateDate',
  'mediaModifyDate',
};

/// Shift a supported date stamp while preserving its interpretation.
///
/// EXIF dates are wall times without a zone. ISO dates include a `Z` or an
/// explicit offset; arithmetic happens on the represented instant, then the
/// result is formatted in the same original offset.
String offsetDateStamp(String value, Duration amount) {
  final exif = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$')
      .firstMatch(value);
  if (exif != null) {
    final parts = List.generate(6, (i) => int.parse(exif.group(i + 1)!));
    final shifted = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    ).add(amount);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${shifted.year.toString().padLeft(4, '0')}:${two(shifted.month)}:${two(shifted.day)} ${two(shifted.hour)}:${two(shifted.minute)}:${two(shifted.second)}';
  }

  final iso = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (iso == null || !isStrictISODate(value)) {
    throw const FormatException('Video dates require strict ISO 8601.');
  }
  final shiftedInstant = DateTime.parse(value).toUtc().add(amount);
  final zone = iso.group(3)!;
  var shiftedWall = shiftedInstant;
  if (zone != 'Z') {
    final hours = int.parse(zone.substring(1, 3));
    final minutes = int.parse(zone.substring(4, 6));
    final direction = zone.startsWith('-') ? -1 : 1;
    shiftedWall = shiftedWall.add(
      Duration(minutes: direction * (hours * 60 + minutes)),
    );
  }
  String two(int v) => v.toString().padLeft(2, '0');
  final wall =
      '${shiftedWall.year.toString().padLeft(4, '0')}-${two(shiftedWall.month)}-${two(shiftedWall.day)}T${two(shiftedWall.hour)}:${two(shiftedWall.minute)}:${two(shiftedWall.second)}';
  return '$wall${iso.group(2) ?? ''}$zone';
}

/// Apply the batch timestamp spacing to generated patches in selection order.
Map<String, MetadataPatch> offsetBatchDatePatches(
  Map<String, MetadataPatch> patches,
  Duration spacing,
) {
  if (spacing == Duration.zero) return patches;
  return {
    for (final entry in patches.entries.indexed)
      entry.$2.key: entry.$1 == 0
          ? entry.$2.value
          : MetadataPatch(
              values: {
                for (final field in entry.$2.value.values.entries)
                  field.key:
                      (field.value is String &&
                          (sharedDateOffsets.containsKey(field.key) ||
                              movieDateKeys.contains(field.key) ||
                              field.key == 'quickTimeCreationDate'))
                      ? offsetDateStamp(
                          field.value as String,
                          Duration(
                            microseconds: spacing.inMicroseconds * entry.$1,
                          ),
                        )
                      : field.value,
              },
              removals: entry.$2.value.removals,
            ),
  };
}

/// Preserve each destination photo's kept zone and a randomized instant.
/// Explicit wall-time edits retain their own deliberate timezone semantics.
MetadataPatch randomDatesWithKeptZones(
  MetadataPatch generated, {
  required Set<String> keepFields,
  required Map<String, String> destinationMetadata,
  Set<String> fixedDates = const {},
}) {
  final values = {...generated.values};
  final removals = {...generated.removals};
  for (final entry in sharedDateOffsets.entries) {
    if (!keepFields.contains(entry.value) ||
        fixedDates.contains(entry.key) ||
        !values.containsKey(entry.key)) {
      continue;
    }
    final instant = datesForMedia(
      MetadataPatch(
        values: {
          entry.key: values[entry.key]!,
          if (values.containsKey(entry.value))
            entry.value: values[entry.value]!,
        },
      ),
      image: false,
    );
    final wall = datesForMedia(
      instant,
      image: true,
      keptOffsets: destinationMetadata,
      keepFields: {entry.value},
    );
    values[entry.key] = wall.values[entry.key]!;
    values.remove(entry.value);
    removals.remove(entry.value);
  }
  return MetadataPatch(values: values, removals: removals);
}

/// Adapt a frozen date intent for each actual media format in a mixed batch.
/// An EXIF wall time needs its explicit offset before it can become an instant.
MetadataPatch datesForMedia(
  MetadataPatch patch, {
  required bool image,
  Map<String, String> keptOffsets = const {},
  Set<String> keepFields = const {},
}) {
  if (patch.values.isNotEmpty || patch.removals.isNotEmpty) {
    final invalid = patch.validate();
    if (invalid != null) throw FormatException(invalid);
  }
  final values = {...patch.values};
  final removals = {...patch.removals};
  final photoGroup = sharedDateOffsets.keys.every(
    (key) =>
        patch.values[key] is String &&
        RegExp(r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$')
            .hasMatch(patch.values[key] as String),
  );
  for (final entry in sharedDateOffsets.entries) {
    final text = values[entry.key];
    if (text is! String) continue;
    final exif = RegExp(r'^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$')
        .hasMatch(text);
    if (!image && exif) {
      final zone = values[entry.value] ?? keptOffsets[entry.value];
      if (zone is! String ||
          !RegExp(r'^[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00)$')
              .hasMatch(zone)) {
        throw const FormatException(
          'Dates need an explicit time zone. Use Set date & time or enter a date with its offset.',
        );
      }
      values[entry.key] = DateTime.parse(
        '${text.substring(0, 10).replaceAll(':', '-')}T${text.substring(11)}$zone',
      ).toUtc().toIso8601String();
    } else if (image && !exif) {
      if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(text)) {
        throw const FormatException(
          'Video dates require an explicit time zone.',
        );
      }
      final instant = DateTime.parse(text).toUtc();
      final zone =
          values[entry.value] ??
          (removals.contains(entry.value) ? null : keptOffsets[entry.value]);
      DateTime wall = instant.toLocal();
      String? retainedZone;
      if (zone != null && zone.toString().isNotEmpty) {
        final match = RegExp(
          r'^([+-])(?:(0[0-9]|1[0-3]):([0-5][0-9])|(14):(00))$',
        ).firstMatch(zone.toString());
        if (match == null) {
          throw const FormatException(
            'The destination photo time zone is invalid.',
          );
        }
        final minutes =
            int.parse(match.group(2) ?? match.group(4)!) * 60 +
            int.parse(match.group(3) ?? match.group(5)!);
        wall = instant.add(
          Duration(minutes: match.group(1) == '-' ? -minutes : minutes),
        );
        retainedZone = zone.toString();
      } else if (keepFields.contains(entry.value)) {
        throw const FormatException(
          'Keeping a missing photo time zone cannot represent this ISO date. Set its time zone or use Set date & time.',
        );
      }
      final converted = captureDatePatch(wall, image: true);
      values[entry.key] = converted.values[entry.key]!;
      if (retainedZone != null &&
          !removals.contains(entry.value) &&
          !keepFields.contains(entry.value)) {
        values.putIfAbsent(entry.value, () => retainedZone!);
      }
      if (retainedZone == null &&
          !removals.contains(entry.value) &&
          !keepFields.contains(entry.value)) {
        values.putIfAbsent(entry.value, () => converted.values[entry.value]!);
      }
    }
  }
  if (!image) {
    final stamp = values['dateTimeOriginal'];
    // The calendar and coherent saved date groups set all three common dates.
    // Carry that complete intent into movie/track/media date headers as well.
    if (photoGroup &&
        stamp != null &&
        values['createDate'] == stamp &&
        values['modifyDate'] == stamp) {
      for (final key in movieDateKeys) {
        if (!removals.contains(key) && !keepFields.contains(key)) {
          values.putIfAbsent(key, () => stamp);
        }
      }
    }
  }
  final incompatible = image ? movieDateKeys : sharedDateOffsets.values.toSet();
  for (final key in incompatible) {
    values.remove(key);
    removals.remove(key);
  }
  return MetadataPatch(values: values, removals: removals);
}

/// Photos use EXIF wall time with explicit offsets. Videos use ISO 8601 UTC.
/// This changes metadata only; it never alters recording duration or media time.
MetadataPatch captureDatePatch(DateTime selected, {required bool image}) {
  String two(int value) => value.toString().padLeft(2, '0');
  if (!image) {
    final stamp = selected.toUtc().toIso8601String();
    return MetadataPatch(
      values: {
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
        ])
          key: stamp,
      },
    );
  }
  final stamp =
      '${selected.year}:${two(selected.month)}:${two(selected.day)} '
      '${two(selected.hour)}:${two(selected.minute)}:${two(selected.second)}';
  final offset = selected.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final zone =
      '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}:${two(minutes % 60)}';
  return MetadataPatch(
    values: {
      for (final key in ['dateTimeOriginal', 'createDate', 'modifyDate'])
        key: stamp,
      for (final key in [
        'offsetTime',
        'offsetTimeOriginal',
        'offsetTimeDigitized',
      ])
        key: zone,
    },
  );
}
