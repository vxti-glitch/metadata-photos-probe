import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/app_theme.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  for (final theme in [AppTheme.lightTheme(), AppTheme.darkTheme()]) {
    test('${theme.brightness.name} controls and copy retain contrast', () {
      final scheme = theme.colorScheme;
      final colors = theme.brightness == Brightness.light
          ? AppTheme.light
          : AppTheme.dark;
      for (final pair in [
        (scheme.primary, scheme.onPrimary),
        (scheme.secondary, scheme.onSecondary),
        (scheme.tertiary, scheme.onTertiary),
        (scheme.primaryContainer, scheme.onPrimaryContainer),
        (scheme.secondaryContainer, scheme.onSecondaryContainer),
        (scheme.tertiaryContainer, scheme.onTertiaryContainer),
        (scheme.error, scheme.onError),
        (scheme.errorContainer, scheme.onErrorContainer),
        (colors.surface, colors.text),
        (colors.surface, colors.muted),
        (colors.raised, colors.muted),
        (colors.raised, colors.success),
        (colors.raised, colors.error),
        (colors.background, colors.subtle),
      ]) {
        expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
    });

    test('${theme.brightness.name} Material roles stay neutral', () {
      final scheme = theme.colorScheme;
      for (final color in [
        scheme.primary,
        scheme.secondary,
        scheme.tertiary,
        scheme.primaryContainer,
        scheme.secondaryContainer,
        scheme.tertiaryContainer,
        scheme.surface,
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
        scheme.inverseSurface,
      ]) {
        expect(color.r, color.g);
        expect(color.g, color.b);
      }
    });
  }
}
