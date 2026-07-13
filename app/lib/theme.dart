// Design tokens lifted straight from the "Ledger" direction of
// SlicePay Screens.dc.html (screens 1a-1f). Paper surfaces, ink type,
// tabular mono money. Money color always means the same thing everywhere:
// green = owed to you, coral = you owe, gray = settled/neutral.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SliceColors {
  static const paper = Color(0xFFF7F5F0);
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0xFFE7E2D8);
  static const borderSoft = Color(0xFFEFEBE2);
  static const chip = Color(0xFFEDE9DF);
  static const ink = Color(0xFF1B1915);
  static const muted = Color(0xFF7D776B);
  static const positive = Color(0xFF3E9C6E); // oklch(0.52 0.12 155) approx
  static const negative = Color(0xFFC1543B); // oklch(0.55 0.13 30) approx
  static const settled = muted;
}

ThemeData sliceTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: SliceColors.paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: SliceColors.ink,
      surface: SliceColors.paper,
    ),
    textTheme: GoogleFonts.schibstedGroteskTextTheme(),
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: SliceColors.paper,
      foregroundColor: SliceColors.ink,
      elevation: 0,
    ),
  );
}

/// Money font — every figure in the app renders through this.
TextStyle moneyStyle({double size = 15, FontWeight weight = FontWeight.w600, Color? color}) =>
    GoogleFonts.splineSansMono(fontSize: size, fontWeight: weight, color: color ?? SliceColors.ink);
