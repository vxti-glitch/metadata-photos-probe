import 'metadata_patch.dart';

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
