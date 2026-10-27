import 'package:flutter/material.dart';

/// Shared colors for the editor, Settings and every nested route.
@immutable
class AppTheme {
  const AppTheme._({
    required this.background,
    required this.surface,
    required this.raised,
    required this.border,
    required this.text,
    required this.muted,
    required this.subtle,
    required this.accent,
    required this.success,
    required this.error,
    required this.errorSurface,
    required this.errorBorder,
    required this.warning,
    required this.warningSurface,
  });

  final Color background;
  final Color surface;
  final Color raised;
  final Color border;
  final Color text;
  final Color muted;
  final Color subtle;
  final Color accent;
  final Color success;
  final Color error;
  final Color errorSurface;
  final Color errorBorder;
  final Color warning;
  final Color warningSurface;

  static const light = AppTheme._(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFF6F6F6),
    border: Color(0xFFCFCFCF),
    text: Color(0xFF252525),
    muted: Color(0xFF545454),
    subtle: Color(0xFF545454),
    accent: Color(0xFF252525),
    success: Color(0xFF18733A),
    error: Color(0xFFB4232D),
    errorSurface: Color(0xFFFFEDEF),
    errorBorder: Color(0xFFE8BBC0),
    warning: Color(0xFF875200),
    warningSurface: Color(0xFFFFF4D9),
  );

  static const dark = AppTheme._(
    background: Color(0xFF252525),
    surface: Color(0xFF303030),
    raised: Color(0xFF303030),
    border: Color(0xFF7D7D7D),
    text: Color(0xFFFFFFFF),
    muted: Color(0xFFCFCFCF),
    subtle: Color(0xFFCFCFCF),
    accent: Color(0xFFCFCFCF),
    success: Color(0xFF62D58B),
    error: Color(0xFFFFA2AA),
    errorSurface: Color(0xFF2C1419),
    errorBorder: Color(0xFF63313A),
    warning: Color(0xFFFFD08B),
    warningSurface: Color(0xFF2C2414),
  );

  static AppTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  static ThemeData lightTheme() => _data(Brightness.light, light);
  static ThemeData darkTheme() => _data(Brightness.dark, dark);

  static ThemeData _data(Brightness brightness, AppTheme colors) {
    final dark = brightness == Brightness.dark;
    final onAccent = dark ? light.text : light.surface;
    // Explicit neutral roles keep Material controls free of seed-generated tints.
    final scheme = ColorScheme(
      brightness: brightness,
      primary: colors.accent,
      onPrimary: onAccent,
      primaryContainer: colors.raised,
      onPrimaryContainer: colors.text,
      secondary: colors.accent,
      onSecondary: onAccent,
      secondaryContainer: colors.raised,
      onSecondaryContainer: colors.text,
      tertiary: colors.accent,
      onTertiary: onAccent,
      tertiaryContainer: colors.raised,
      onTertiaryContainer: colors.text,
      primaryFixed: light.raised,
      primaryFixedDim: light.raised,
      onPrimaryFixed: light.text,
      onPrimaryFixedVariant: light.text,
      secondaryFixed: light.raised,
      secondaryFixedDim: light.raised,
      onSecondaryFixed: light.text,
      onSecondaryFixedVariant: light.text,
      tertiaryFixed: light.raised,
      tertiaryFixedDim: light.raised,
      onTertiaryFixed: light.text,
      onTertiaryFixedVariant: light.text,
      surface: colors.surface,
      onSurface: colors.text,
      onSurfaceVariant: colors.muted,
      surfaceDim: colors.raised,
      surfaceBright: colors.surface,
      surfaceContainerLowest: colors.background,
      surfaceContainerLow: colors.surface,
      surfaceContainer: colors.surface,
      surfaceContainerHigh: colors.raised,
      surfaceContainerHighest: colors.raised,
      surfaceTint: Colors.transparent,
      inverseSurface: dark ? light.surface : AppTheme.dark.surface,
      onInverseSurface: dark ? light.text : AppTheme.dark.text,
      inversePrimary: dark ? light.accent : AppTheme.dark.accent,
      outline: colors.border,
      outlineVariant: colors.border,
      shadow: Colors.black,
      scrim: Colors.black,
      error: colors.error,
      onError: dark ? colors.errorSurface : Colors.white,
      errorContainer: colors.errorSurface,
      onErrorContainer: colors.error,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.surface,
      dividerColor: colors.border,
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      iconTheme: IconThemeData(color: colors.text),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.background,
        foregroundColor: colors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        modalBackgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: colors.text),
      ),
      listTileTheme: ListTileThemeData(
        textColor: colors.text,
        iconColor: colors.muted,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        hintStyle: TextStyle(color: colors.muted),
        labelStyle: TextStyle(color: colors.muted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.border),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.accent.withValues(alpha: 0.14),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.accent,
        selectionColor: colors.accent.withValues(alpha: 0.25),
        selectionHandleColor: colors.accent,
      ),
    );
  }
}
