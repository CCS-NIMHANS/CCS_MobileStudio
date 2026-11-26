import 'dart:io';

import 'package:flutter/material.dart';

/// Shared clinical light-instrument palette matching CCS_SleepStudio across
/// mobile, tablet, and desktop/laptop screens.
class StudioColors {
  const StudioColors._();

  static const Color canvas = Color(0xFFF3F5F8);
  static const Color surface = Color(0xFFF8F9FB);
  static const Color card = Color(0xFFFFFFFF);
  static const Color elevated = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFD0D7E2);

  // Primary clinical steel-blue accent (#3B6EA5) + high-contrast status inks
  // suitable for white / #F8F9FB instrument surfaces.
  static const Color teal = Color(0xFF3B6EA5);
  static const Color sky = Color(0xFF0284C7);
  static const Color blue = Color(0xFF1E88E5);
  static const Color emerald = Color(0xFF047857);
  static const Color amber = Color(0xFFB45309);
  static const Color red = Color(0xFFDC2626);
  static const Color violet = Color(0xFF6D28D9);

  static const Color textPrimary = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF374151);
  static const Color textMuted = Color(0xFF6B7280);
}

class StudioTheme {
  const StudioTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: StudioColors.teal,
      brightness: Brightness.light,
      surface: StudioColors.card,
      primary: StudioColors.teal,
      secondary: StudioColors.blue,
      error: StudioColors.red,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: StudioColors.canvas,
      fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      appBarTheme: const AppBarTheme(
        backgroundColor: StudioColors.surface,
        foregroundColor: StudioColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: StudioColors.border)),
      ),
      cardTheme: CardThemeData(
        color: StudioColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: StudioColors.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: StudioColors.elevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: StudioColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: StudioColors.border,
        thickness: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: StudioColors.teal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: StudioColors.teal,
          side: const BorderSide(color: StudioColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: StudioColors.card,
        labelStyle: const TextStyle(color: StudioColors.textSecondary),
        hintStyle: const TextStyle(color: StudioColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.teal, width: 1.5),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: StudioColors.textPrimary,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  /// Kept as an alias so any callers referencing StudioTheme.dark() inherit
  /// the unified clinical SleepStudio aesthetic.
  static ThemeData dark() => light();
}
