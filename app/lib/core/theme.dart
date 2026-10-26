import 'package:flutter/material.dart';

/// 颐安云护视觉体系：深青为主（安静可信），暖橙仅用于 SOS / 告警。
class AppTheme {
  static const primary = Color(0xFF0E7490);
  static const primaryDeep = Color(0xFF155E75);
  static const accent = Color(0xFFEA580C);
  static const bg = Color(0xFFF3F7F8);
  static const ok = Color(0xFF16A34A);
  static const warn = Color(0xFFD97706);
  static const danger = Color(0xFFDC2626);
  static const muted = Color(0xFF64748B);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: accent,
      surface: Colors.white,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: primaryDeep,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: Colors.grey.shade200, thickness: 1),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
