import 'package:flutter/material.dart';

/// Paper surfaces, ink hierarchy and a single blue action accent.
ThemeData lanPairTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ink = dark ? const Color(0xFFF1F3FA) : const Color(0xFF111827);
  final secondary = dark ? const Color(0xFFABB3C5) : const Color(0xFF4B5563);
  final border = dark ? const Color(0xFF343B4B) : const Color(0xFFE2E5EB);
  final surface = dark ? const Color(0xFF1B202C) : Colors.white;
  final blue = dark ? const Color(0xFFAEBBFF) : const Color(0xFF2142E7);
  final colors = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
      .copyWith(
        primary: blue,
        onPrimary: dark ? const Color(0xFF111827) : Colors.white,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: secondary,
        outline: dark ? const Color(0xFF7C879E) : const Color(0xFF8C96A7),
        outlineVariant: border,
        surfaceContainerLow: dark
            ? const Color(0xFF222938)
            : const Color(0xFFF4F6FA),
        surfaceContainerHighest: dark
            ? const Color(0xFF2B3345)
            : const Color(0xFFEEF1F8),
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  return base.copyWith(
    scaffoldBackgroundColor: dark
        ? const Color(0xFF121620)
        : const Color(0xFFFAFBFD),
    textTheme: base.textTheme
        .apply(bodyColor: secondary, displayColor: ink)
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall!.copyWith(
            fontSize: 36,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.1,
            color: ink,
          ),
          titleLarge: base.textTheme.titleLarge!.copyWith(
            fontSize: 21,
            height: 1.3,
            fontWeight: FontWeight.w600,
            letterSpacing: -.4,
            color: ink,
          ),
          titleMedium: base.textTheme.titleMedium!.copyWith(
            fontSize: 16,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          bodyLarge: base.textTheme.bodyLarge!.copyWith(
            fontSize: 16,
            height: 1.55,
            color: secondary,
          ),
          bodyMedium: base.textTheme.bodyMedium!.copyWith(
            fontSize: 14,
            height: 1.5,
            color: secondary,
          ),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 68,
      titleTextStyle: base.textTheme.titleLarge!.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -.7,
        color: ink,
      ),
      shape: Border(bottom: BorderSide(color: border)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: surface,
      indicatorColor: blue.withValues(alpha: .09),
      selectedIconTheme: IconThemeData(color: blue),
      unselectedIconTheme: IconThemeData(color: secondary),
      selectedLabelTextStyle: base.textTheme.labelLarge!.copyWith(
        color: ink,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: base.textTheme.labelLarge!.copyWith(
        color: secondary,
      ),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: blue.withValues(alpha: .10),
      indicatorShape: shape,
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF171C27) : const Color(0xFFFAFBFD),
      alignLabelWithHint: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: blue, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        textStyle: base.textTheme.labelLarge!.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        foregroundColor: ink,
        side: BorderSide(color: border),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        textStyle: base.textTheme.labelLarge!.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: blue,
      linearTrackColor: blue.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(8),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
    focusColor: blue.withValues(alpha: .15),
  );
}
