import 'dart:io';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'media_models.dart';

/// Displays only the engine's small PNG derivative, never the original media.
class MediaPreview extends StatelessWidget {
  const MediaPreview({
    super.key,
    required this.session,
    this.height = 220,
    this.width,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
  });

  final MediaSession session;
  final double height;
  final double? width;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final previewPath = session.previewPath;
    Widget fallback() => ColoredBox(
      color: colors.raised,
      child: Center(
        child: Icon(
          !session.inspection.kind.isImage
              ? Icons.videocam_outlined
              : Icons.photo_outlined,
          size: height < 100 ? 24 : 44,
          color: colors.muted,
        ),
      ),
    );

    return Semantics(
      image: true,
      label: 'Preview of ${session.displayName}',
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          height: height,
          width: width ?? double.infinity,
          child: previewPath == null || previewPath.isEmpty
              ? fallback()
              : Image(
                  image: ResizeImage(
                    FileImage(File(previewPath)),
                    width: 512,
                    height: 512,
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => fallback(),
                ),
        ),
      ),
    );
  }
}
