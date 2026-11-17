import 'package:flutter/material.dart';

abstract final class KhotwaPalette {
  static const navy = Color(0xFF17375E);
  static const amber = Color(0xFFE3A343);
  static const cream = Color(0xFFF8F5EF);
  static const ink = Color(0xFF22344B);
  static const muted = Color(0xFF526074);
  static const line = Color(0xFFE8E4DC);
  static const teal = Color(0xFF2F8078);
  static const paleBlue = Color(0xFFEDF2F8);
  static const paleAmber = Color(0xFFFCF0D9);
}

abstract final class KhotwaTheme {
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSansArabic',
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: KhotwaPalette.navy,
      primary: KhotwaPalette.navy,
      secondary: KhotwaPalette.teal,
      tertiary: KhotwaPalette.amber,
      surface: Colors.white,
      error: const Color(0xFFAE3F3C),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w800,
        height: 1.5,
        color: KhotwaPalette.navy,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w800,
        height: 1.5,
        color: KhotwaPalette.navy,
      ),
      headlineSmall: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        height: 1.5,
        color: KhotwaPalette.navy,
      ),
      titleLarge: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        height: 1.5,
        color: KhotwaPalette.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        height: 1.5,
        color: KhotwaPalette.ink,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.6,
        color: KhotwaPalette.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.7, color: KhotwaPalette.ink),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.7,
        color: KhotwaPalette.ink,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.6,
        color: KhotwaPalette.muted,
      ),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: KhotwaPalette.navy,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansArabic',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: KhotwaPalette.navy,
      ),
    ),
    cardTheme: CardThemeData(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: KhotwaPalette.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFD8DDE5)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFD8DDE5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: KhotwaPalette.navy, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      labelStyle: const TextStyle(color: KhotwaPalette.muted, fontSize: 14),
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansArabic',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        side: const BorderSide(color: Color(0xFFCCD5E0)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansArabic',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: KhotwaPalette.navy,
        minimumSize: const Size(48, 48),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 80,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: const Color(0xFFF9E3B9),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'NotoSansArabic',
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? KhotwaPalette.navy
              : KhotwaPalette.muted,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: KhotwaPalette.paleBlue,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelStyle: const TextStyle(
        fontFamily: 'NotoSansArabic',
        fontSize: 12,
        color: KhotwaPalette.navy,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: KhotwaPalette.navy,
      contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansArabic',
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.5,
        color: KhotwaPalette.ink,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'NotoSansArabic',
        fontSize: 13,
        height: 1.7,
        color: KhotwaPalette.muted,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: KhotwaPalette.line,
      thickness: 1,
      space: 24,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: KhotwaPalette.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: KhotwaPalette.navy,
    ),
  );
}
