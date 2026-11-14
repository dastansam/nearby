// How NearBy looks: paper, ink and one green. Colours and the few shared pieces live here so the
// screens only say what they show.
import 'package:flutter/material.dart';

ThemeData nearbyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? const Color(0xFF6FD6AC) : const Color(0xFF0B6E4F),
    onPrimary: dark ? const Color(0xFF06231A) : Colors.white,
    // The balance card: a block of green in either mode.
    primaryContainer: dark ? const Color(0xFF0F3D2E) : const Color(0xFF0B6E4F),
    onPrimaryContainer: dark ? const Color(0xFFE3F3EC) : const Color(0xFFF4F1EA),
    secondary: dark ? const Color(0xFFD9B36A) : const Color(0xFF8A6A1F),
    onSecondary: dark ? const Color(0xFF2A1F05) : Colors.white,
    error: dark ? const Color(0xFFFF8A7A) : const Color(0xFFB3261E),
    onError: dark ? const Color(0xFF3B0A05) : Colors.white,
    surface: dark ? const Color(0xFF121413) : const Color(0xFFF4F1EA),
    onSurface: dark ? const Color(0xFFECE8DF) : const Color(0xFF16181A),
    surfaceContainer: dark ? const Color(0xFF1B1E1C) : const Color(0xFFFBF9F4),
    onSurfaceVariant: dark ? const Color(0xFF9A9D94) : const Color(0xFF6B6B63),
    outlineVariant: dark ? const Color(0xFF2C302D) : const Color(0xFFDDD8CC),
  );
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(64, 54)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle:
          TextStyle(color: scheme.onSurface, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3),
    ),
    // Ink, not green: the green is kept for money and for "it worked".
    filledButtonTheme: FilledButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStatePropertyAll(scheme.onSurface),
        foregroundColor: WidgetStatePropertyAll(scheme.surface),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.onSurface, width: 1.5)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.onSurface,
      contentTextStyle: TextStyle(color: scheme.surface, fontSize: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

/// Small capitals over a section or a figure.
TextStyle labelStyle(BuildContext context, {Color? color}) => TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.4,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );

/// Digits that keep their width, so amounts line up and do not jitter.
const figures = [FontFeature.tabularFigures()];

/// A rounded sheet with a hairline edge.
class Panel extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  const Panel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(18), this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(22);
    return Material(
      color: color ?? scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: color == null ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// An amount as formatUsdc writes it ("2.50 USDC"): the figure large, the unit small beside it.
class Amount extends StatelessWidget {
  final String formatted;
  final double size;
  final Color? color;
  const Amount(this.formatted, {super.key, this.size = 44, this.color});

  @override
  Widget build(BuildContext context) {
    final ink = color ?? Theme.of(context).colorScheme.onSurface;
    final cut = formatted.lastIndexOf(' ');
    final figure = cut < 0 ? formatted : formatted.substring(0, cut);
    final unit = cut < 0 ? '' : formatted.substring(cut + 1);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: figure,
          style: TextStyle(
              fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -size / 28, height: 1.05, fontFeatures: figures),
        ),
        if (unit.isNotEmpty)
          TextSpan(
            text: '  $unit',
            style: TextStyle(fontSize: size / 3.2, fontWeight: FontWeight.w600, letterSpacing: 0.6),
          ),
      ]),
      style: TextStyle(color: ink),
      textAlign: TextAlign.center,
    );
  }
}
