/// One visual identity for the whole app: colours, type, shapes, and the
/// component themes every screen inherits.
///
/// Screens should read these through `Theme.of(context)` rather than naming
/// colours themselves — that is what makes a palette change a one-file edit,
/// and what stops five shades of "grey card" from accumulating across
/// eleven screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_constants.dart';

/// Semantic colours. Most are *not* derivable from the seed
/// (success/warning states); the two chat bubble roles ARE derived from it,
/// so they follow the theme-colour setting instead of staying Matrix green.
class AppColors {
  AppColors._();

  /// Phosphor green brand — Clawziod look (was Matrix 0xFF00FF41, indigo
  /// before that). Mutable on purpose: the theme-colour setting in
  /// Settings writes this before the app theme is built, so the theme and
  /// every brand-coloured widget follow the picked colour. Defaults to the
  /// Matrix green.
  static Color brand = AppConstants.primaryColor;

  /// Secondary accent for AI-authored surfaces and progress: Clawziod's
  /// emerald green, which reads as "machine" against the brand green without
  /// competing. Was Matrix light green 0xFF4ADE80.
  static const Color accent = Color(0xFF10B981);

  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  /// Page background — upstream LocalMind's soft charcoal, not black.
  /// Upstream's page is *lighter* than its panels, the reverse of the old
  /// terminal look (pitch black 0xFF050807 over near-black cards).
  static const Color background = Color(0xFF212121);

  /// Card / sheet surface — upstream's panel charcoal.
  static const Color surface = Color(0xFF171717);

  /// Raised surface (dialogs, expanded cards, the input bar) — upstream's
  /// input/card fill.
  static const Color surfaceHigh = Color(0xFF2F2F2F);

  /// The one border colour: upstream's thin grey. Cards, dialogs and bubbles
  /// use this — nothing gets a green border any more (build #118).
  static const Color border = Color(0xFF424242);

  /// Primary text — upstream's near-white.
  static const Color text = Color(0xFFECECEC);

  /// Muted text — upstream's grey.
  static const Color muted = Color(0xFFB4B4B4);

  // ------------------------------------------------------------ light mode
  // Upstream LocalMind's light tokens (build #120): a near-white page,
  // pure-white cards, black text, pale grey borders. The accent is NOT
  // redefined here: the seed stays [brand], so the picked colour seeds
  // both modes and the colour picker keeps working in light mode.
  static const Color lightBackground = Color(0xFFFAFAFA);
  static const Color lightSurface = Color(0xFFFFFFFF);

  /// Raised surface in light mode (dialogs, expanded cards, the input
  /// bar) — upstream's light input fill, a whisper darker than the page
  /// so a raised surface still reads as raised on white.
  static const Color lightSurfaceHigh = Color(0xFFF4F4F5);

  /// The step below the page background in light mode. Dark mode's
  /// equivalent (0xFF1E1E1E) sits just below its background; light mode's
  /// sits just below #FAFAFA, so it is the same fill as [lightSurfaceHigh].
  static const Color lightSurfaceLow = Color(0xFFF4F4F5);

  static const Color lightBorder = Color(0xFFE5E5E5);
  static const Color lightText = Color(0xFF0A0A0A);
  static const Color lightMuted = Color(0xFF71717A);

  /// The model's bubble in light mode — a near-white grey, not a brand
  /// tint: the dark tint (lightness 0.10) would be a black slab on a white
  /// page, and a pale brand tint would make the two roles hard to tell
  /// apart once the user's bubble is pale too. Fixed grey, so it never
  /// depends on the pick.
  static const Color lightAiBubble = Color(0xFFF5F5F4);

  /// The user's bubble in light mode — a pale tint of the picked brand
  /// colour: same hue as the brand, so it follows the theme-colour
  /// setting, but light enough (0.88) that dark text stays readable on
  /// it. With the default brand this resolves to a pale green.
  static Color get lightUserBubble =>
      _brandTint(saturation: 0.45, lightness: 0.88);

  /// The bubble fill for [brightness]: the dark tints below in dark mode,
  /// the pale variants above in light mode. Screens that render bubbles
  /// must read through here (with the theme's brightness), not through
  /// [aiBubble] / [userBubble] directly, or light mode gets dark bubbles.
  static Color aiBubbleFor(Brightness brightness) =>
      brightness == Brightness.light ? lightAiBubble : aiBubble;

  /// See [aiBubbleFor].
  static Color userBubbleFor(Brightness brightness) =>
      brightness == Brightness.light ? lightUserBubble : userBubble;

  /// The model's own bubble — a dark tint of the picked brand colour, so
  /// it follows the theme-colour setting instead of staying Matrix green.
  /// Same hue as the brand, low saturation and lightness, so the
  /// near-white transcript text stays readable on it whatever the pick.
  /// With the default brand (0xFF00FF66) this resolves to (18, 33, 24),
  /// the old 0xFF122015 to within a shade.
  static Color get aiBubble => _brandTint(saturation: 0.28, lightness: 0.10);

  /// The user's bubble — a stronger tint of the picked brand colour, so
  /// it follows the theme-colour setting too. With the default brand this
  /// resolves to (22, 162, 78), the old 0xFF16A34A to within a shade.
  /// Lighter than [aiBubble] so the two roles stay distinct.
  static Color get userBubble => _brandTint(saturation: 0.76, lightness: 0.36);

  /// A tint of [brand] at a fixed saturation and lightness: the hue is
  /// the brand's, so the colour follows the theme-colour setting, while
  /// the lightness is fixed, so text contrast never depends on the pick.
  static Color _brandTint({
    required double saturation,
    required double lightness,
  }) {
    final hsl = HSLColor.fromColor(brand);
    return hsl.withSaturation(saturation).withLightness(lightness).toColor();
  }
}

/// The per-mode values a theme is built from: one palette per mode, one
/// [AppTheme] construction shared by both, so a token can never drift
/// between the two themes by being edited in one getter and not the other.
class _Palette {
  const _Palette({
    required this.background,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.border,
    required this.text,
    required this.muted,
  });

  final Color background;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color border;
  final Color text;
  final Color muted;
}

class AppTheme {
  AppTheme._();

  /// The dark palette — upstream's stepped charcoals.
  static const _darkPalette = _Palette(
    background: AppColors.background,
    surface: AppColors.surface,
    surfaceLow: Color(0xFF1E1E1E),
    surfaceHigh: AppColors.surfaceHigh,
    border: AppColors.border,
    text: AppColors.text,
    muted: AppColors.muted,
  );

  /// The light palette — upstream's near-white tokens (build #120).
  static const _lightPalette = _Palette(
    background: AppColors.lightBackground,
    surface: AppColors.lightSurface,
    surfaceLow: AppColors.lightSurfaceLow,
    surfaceHigh: AppColors.lightSurfaceHigh,
    border: AppColors.lightBorder,
    text: AppColors.lightText,
    muted: AppColors.lightMuted,
  );

  /// Corner radii, upstream LocalMind's values: 12 for cards and inputs,
  /// 8 for buttons. [radiusMedium] stays 12 — it is what cards, bubbles and
  /// inputs read in the screens — while buttons read [radiusSmall].
  static const double radiusLarge = 12;
  static const double radiusMedium = 12;
  static const double radiusSmall = 8;

  /// The stored `theme_mode` value for the default mode: Dark. The setting
  /// defaults to this (see the settings defaults) and
  /// [themeModeFromSetting] falls back to it for a missing or hand-edited
  /// value, so a user who set a colour before this setting existed stays
  /// on the dark theme they have always had.
  static const String defaultThemeModeSetting = 'dark';

  /// Parse the stored `theme_mode` setting ('light' / 'dark' / 'system')
  /// into the [ThemeMode] the app root hands to [MaterialApp]. Anything
  /// unrecognised — including null — is Dark, the default.
  static ThemeMode themeModeFromSetting(String? value) {
    return switch (value) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  /// The dark theme.
  ///
  /// The seed is [AppColors.brand], which the app root sets from the
  /// theme-colour setting before building the theme — Matrix green unless
  /// the user picked another colour. Everything derived from the seed
  /// (buttons, sliders, selected states) follows it; the fixed charcoal
  /// surfaces stay put.
  ///
  /// Dark is not a preference here: the app is a long-session chat client and
  /// a model download progress screen, both of which people run at night.
  /// The surfaces are upstream's stepped charcoals (`surface` darker than
  /// `background`, `surfaceHigh` lighter than both) instead of relying on
  /// elevation shadows, because shadows on charcoal carry little
  /// information and elevation then reads as a border instead.
  static ThemeData get dark => _build(Brightness.dark, _darkPalette);

  /// The light theme (build #120): upstream LocalMind's light tokens —
  /// near-white page, pure-white cards, black text, pale grey borders.
  /// The accent is still the picked brand colour: the seed is the same
  /// [AppColors.brand] in both modes, so the colour picker keeps working
  /// in light mode exactly as it does in dark.
  static ThemeData get light => _build(Brightness.light, _lightPalette);

  /// One construction for both modes: the only differences are the
  /// palette and the brightness, so a component theme added here lands
  /// in both modes at once and can never be dark-only by accident.
  static ThemeData _build(Brightness brightness, _Palette p) {
    final seed = AppColors.brand;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(
      primary: seed,
      secondary: AppColors.accent,
      surface: p.surface,
      surfaceContainerLowest: p.background,
      surfaceContainerLow: p.surfaceLow,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.surfaceHigh,
      surfaceContainerHighest: p.surfaceHigh,
      error: AppColors.danger,
      outline: p.border,
      onSurface: p.text,
      onSurfaceVariant: p.muted,
    );

    final text = _textTheme(scheme, p);

    return ThemeData(
      useMaterial3: true,
      // Body/UI text is the platform default sans (Roboto on Android), not
      // Inter — deliberately (build #118). Inter was tried via google_fonts
      // 6.3.3 (resolves cleanly, runtime download, no .ttf in the repo) and
      // rejected: wiring it into this getter makes every plain unit test
      // that builds the theme fail. GoogleFonts.interTextTheme() fires a
      // fire-and-forget font load that needs ServicesBinding, path_provider
      // and the network, and its loader *rethrows* on failure as an
      // unhandled async error — so the theme smoke test, whose whole point
      // is to be a binding-free plain-expect guard, goes red, and so would
      // any future plain test that touches AppTheme.dark. The fixes are all
      // worse than the font: network-dependent test runs, or .ttf test
      // fixtures (binary files the push path cannot push), or hardcoding
      // google_fonts' internal variant family names. Literal Inter can
      // still land later as bundled .ttf assets through a push route that
      // carries binaries. Monospace survives only where it is content, not
      // chrome: code blocks (flutter_markdown pins those itself) and the
      // CLAWZILLA wordmark.
      colorScheme: scheme,
      scaffoldBackgroundColor: p.background,
      textTheme: text,

      // ------------------------------------------------------------- chrome
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: p.background,
        foregroundColor: scheme.onSurface,
        // The status-bar icons follow the theme, not the launch default:
        // light icons on the charcoal theme, dark icons on the white one.
        // The splash (no AppBar) is covered the same way by the app root.
        systemOverlayStyle: brightness == Brightness.light
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
        height: 68,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
      ),

      // --------------------------------------------------------- containers
      cardTheme: CardThemeData(
        elevation: 0,
        color: p.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          // Upstream look: a thin grey border, no green, no glow.
          side: BorderSide(color: p.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: p.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge + 4),
          side: BorderSide(color: p.border),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        elevation: 0,
        backgroundColor: p.surfaceHigh,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.surfaceHigh,
        contentTextStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
      ),

      // ----------------------------------------------------------- controls
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, 48),
          elevation: 0,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall),
            ),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),

      // ------------------------------------------------------------ inputs
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceHigh,
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: p.surfaceHigh,
        circularTrackColor: p.surfaceHigh,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.22),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        labelStyle: text.labelMedium,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        radius: const Radius.circular(8),
        thickness: WidgetStatePropertyAll(6),
      ),
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      // Every route in the app is pushed with MaterialPageRoute, so this is
      // where the transition is decided: a short fade-up instead of the
      // platform's full-width slide. Pushes here are shallow (settings, model
      // picker, dialogs) and a slide implies a depth hierarchy that does not
      // exist.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // Android only: the app locks to portrait and targets Android, and
          // CupertinoPageTransitionsBuilder is not in material's export
          // (it lives in cupertino.dart) — naming it here does not compile.
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// The type scale.
  ///
  /// Slightly tighter than the Material defaults (line height 1.3 instead of
  /// 1.4 for body) because chat is a line-oriented format: looser leading
  /// makes a transcript feel like a slide deck. Sizes are otherwise stock so
  /// the system font-scaling slider keeps behaving the way users expect.
  /// No fontFamily is pinned here: body/UI text renders in the platform
  /// default sans (see the note on the ThemeData above for why Inter is
  /// not wired in).
  static TextTheme _textTheme(ColorScheme scheme, _Palette p) {
    final color = p.text;
    final muted = p.muted;

    return TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: color,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: color,
      ),
      titleLarge: TextStyle(
        fontSize: 19,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: color,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.45, color: color),
      bodyMedium: TextStyle(fontSize: 14.5, height: 1.45, color: color),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.4, color: muted),
      labelLarge: TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: color,
      ),
      labelMedium: TextStyle(
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
    );
  }
}
