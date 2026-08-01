// Design tokens lifted straight from the "Ledger" direction of
// SlicePay Screens.dc.html (screens 1a-1f), plus the dark tokens from
// screen 1g's alternate take for the dark variant. Paper surfaces, ink
// type, tabular mono money. Money color always means the same thing
// everywhere: green = owed to you, coral = you owe, gray = settled/neutral.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Theme-aware design tokens. Read via `context.slice` rather than a
/// static class, so every screen automatically gets the light or dark
/// palette depending on the system's theme setting.
class SliceTheme extends ThemeExtension<SliceTheme> {
  const SliceTheme({
    required this.paper,
    required this.card,
    required this.border,
    required this.borderSoft,
    required this.chip,
    required this.ink,
    required this.muted,
    required this.positive,
    required this.negative,
  });

  final Color paper;
  final Color card;
  final Color border;
  final Color borderSoft;
  final Color chip;
  final Color ink;
  final Color muted;
  final Color positive;
  final Color negative;

  /// Settled/neutral money — same as muted.
  Color get settled => muted;

  static const light = SliceTheme(
    paper: Color(0xFFF7F5F0),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFE7E2D8),
    borderSoft: Color(0xFFEFEBE2),
    chip: Color(0xFFEDE9DF),
    ink: Color(0xFF1B1915),
    muted: Color(0xFF7D776B),
    positive: Color(0xFF3E9C6E), // oklch(0.52 0.12 155) approx
    negative: Color(0xFFC1543B), // oklch(0.55 0.13 30) approx
  );

  // Dark tokens from screen 1g (SlicePay Screens.dc.html's dark home take).
  static const dark = SliceTheme(
    paper: Color(0xFF141310),
    card: Color(0xFF201F1B),
    border: Color(0xFF2A2823),
    borderSoft: Color(0xFF232119),
    chip: Color(0xFF232119),
    ink: Color(0xFFF4F1E9),
    muted: Color(0xFFA39D90), // approximates rgba(244,241,233,.55-.65)
    positive: Color(0xFF6FCF97), // oklch(0.8 0.14 155) approx
    negative: Color(0xFFE8896B), // oklch(0.78 0.14 30) approx
  );

  @override
  SliceTheme copyWith({
    Color? paper,
    Color? card,
    Color? border,
    Color? borderSoft,
    Color? chip,
    Color? ink,
    Color? muted,
    Color? positive,
    Color? negative,
  }) =>
      SliceTheme(
        paper: paper ?? this.paper,
        card: card ?? this.card,
        border: border ?? this.border,
        borderSoft: borderSoft ?? this.borderSoft,
        chip: chip ?? this.chip,
        ink: ink ?? this.ink,
        muted: muted ?? this.muted,
        positive: positive ?? this.positive,
        negative: negative ?? this.negative,
      );

  @override
  SliceTheme lerp(ThemeExtension<SliceTheme>? other, double t) {
    if (other is! SliceTheme) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return SliceTheme(
      paper: c(paper, other.paper),
      card: c(card, other.card),
      border: c(border, other.border),
      borderSoft: c(borderSoft, other.borderSoft),
      chip: c(chip, other.chip),
      ink: c(ink, other.ink),
      muted: c(muted, other.muted),
      positive: c(positive, other.positive),
      negative: c(negative, other.negative),
    );
  }
}

extension SliceThemeContext on BuildContext {
  SliceTheme get slice => Theme.of(this).extension<SliceTheme>()!;
}

ThemeData sliceLightTheme() => _buildTheme(SliceTheme.light, Brightness.light);
ThemeData sliceDarkTheme() => _buildTheme(SliceTheme.dark, Brightness.dark);

ThemeData _buildTheme(SliceTheme colors, Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: colors.paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: colors.ink,
      brightness: brightness,
      surface: colors.paper,
    ),
    textTheme: (brightness == Brightness.dark
            ? GoogleFonts.schibstedGroteskTextTheme(ThemeData(brightness: brightness).textTheme)
            : GoogleFonts.schibstedGroteskTextTheme())
        .apply(bodyColor: colors.ink, displayColor: colors.ink),
    extensions: [colors],
  );
  final pillShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: colors.paper,
      foregroundColor: colors.ink,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.ink,
        foregroundColor: colors.paper,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: pillShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.ink,
        side: BorderSide(color: colors.ink, width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: pillShape,
      ),
    ),
  );
}

/// Money font — every figure in the app renders through this.
TextStyle moneyStyle({double size = 15, FontWeight weight = FontWeight.w600, required Color color}) =>
    GoogleFonts.splineSansMono(fontSize: size, fontWeight: weight, color: color);

/// The small tracked-out uppercase label repeated above every section
/// ("PAID BY", "SPLIT", "GROUP NAME", ...) — one definition instead of a
/// copy-pasted TextStyle at each call site.
TextStyle sectionLabelStyle(Color color) =>
    TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: color);

/// The large page/screen title ("SlicePay", a group's name, ...).
TextStyle pageTitleStyle(Color color, {double size = 26}) =>
    TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: color);
