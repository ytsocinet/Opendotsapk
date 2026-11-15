/// Smoke tests for the theme: the values every screen reads through
/// `Theme.of(context)`.
///
/// These are plain `expect` calls on the returned [ThemeData]. Nothing is
/// pumped, no plugin is touched, and no platform channel is invoked, because
/// this file has to be one of the cheapest and most reliable tests in the
/// suite — a theme regression shows up as eleven screens drifting apart, and
/// the cheapest guard is to pin the handful of values they all depend on.
///
/// What is asserted is deliberately the *contract*, not a rendering: that the
/// dark theme really is dark, that the scaffold sits on the app's own
/// background colour, and that every hand-picked colour in [AppColors] is
/// fully opaque. A translucent brand colour would render as an unpredictable
/// blend over whatever is behind it and is exactly the kind of thing that
/// looks fine on one surface and wrong on another.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/core/theme/app_theme.dart';

void main() {
  group('AppTheme.dark', () {
    test('is a dark Material 3 theme', () {
      final theme = AppTheme.dark;

      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.brightness, Brightness.dark);
      // ThemeData derives its own `brightness` from the colour scheme; if these
      // ever disagree, a screen reading one and a widget resolving the other
      // pick different text colours.
      expect(theme.brightness, Brightness.dark);
    });

    test(
      'puts the scaffold on the app background, not on the card surface',
      () {
        final theme = AppTheme.dark;

        expect(theme.scaffoldBackgroundColor, AppColors.background);
        // Cards must be a *different*, lighter step or elevation carries no
        // information at all on a near-black page.
        expect(theme.colorScheme.surface, isNot(AppColors.background));
      },
    );

    test('exposes the brand and accent colours through the scheme', () {
      final scheme = AppTheme.dark.colorScheme;

      expect(scheme.primary, AppColors.brand);
      expect(scheme.secondary, AppColors.accent);
      expect(scheme.error, AppColors.danger);
    });

    test('is built without throwing and has a usable text scale', () {
      final theme = AppTheme.dark;

      // Touching the getters forces construction of the nested component
      // themes, so a malformed one would surface here rather than on a screen.
      expect(theme.textTheme.titleLarge, isNotNull);
      expect(theme.textTheme.bodyMedium, isNotNull);
      expect(theme.cardTheme, isNotNull);
      expect(theme.scaffoldBackgroundColor, isNotNull);
    });

    test('keeps the shared corner radii', () {
      expect(AppTheme.radiusLarge, 16.0);
      expect(AppTheme.radiusMedium, 12.0);
      expect(AppTheme.radiusSmall, 8.0);
    });
  });

  group('AppColors', () {
    /// Every colour the app names by hand, not through the scheme. A change to
    /// this list is a reminder that the new colour also needs an opaque alpha.
    ///
    /// Not `const`: `brand` stopped being a constant when the theme-colour
    /// setting landed (build #85) — it is set from the setting before the
    /// theme is built, so a const map naming it cannot compile.
    final Map<String, Color> palette = {
      'brand': AppColors.brand,
      'accent': AppColors.accent,
      'success': AppColors.success,
      'warning': AppColors.warning,
      'danger': AppColors.danger,
      'background': AppColors.background,
      'surface': AppColors.surface,
      'surfaceHigh': AppColors.surfaceHigh,
      'aiBubble': AppColors.aiBubble,
      'userBubble': AppColors.userBubble,
    };

    test('every colour is fully opaque', () {
      palette.forEach((name, colour) {
        expect(colour.a, 1.0, reason: '$name must not be translucent');
      });
    });

    test('the brand and the AI accent are the documented values', () {
      // The two colours the product is specified in. Pinned so a palette edit
      // is a deliberate act rather than an accident. Clawziod phosphor green
      // since the reskin (Nov 7, 2026): brand was Matrix 0xFF00FF41, before
      // that indigo 0xFF6366F1; accent was Matrix light green 0xFF4ADE80,
      // before that cyan 0xFF22D3EE.
      //
      // This pins the DEFAULT brand. The user can pick another colour in
      // Settings → Appearance (build #85), which writes AppColors.brand;
      // nothing in the test suite does that, so the default holds here.
      expect(AppColors.brand, const Color(0xFF00FF66));
      expect(AppColors.accent, const Color(0xFF10B981));
    });

    test('uses the Clawziod canvas and monospace type', () {
      // Pitch black, not the old near-black; monospace on every style, so a
      // screen that hand-writes its own TextStyle without the theme font is
      // the only way non-mono text can still slip in.
      expect(AppColors.background, const Color(0xFF050807));
      final theme = AppTheme.dark;
      expect(theme.textTheme.bodyMedium?.fontFamily, 'monospace');
      expect(theme.textTheme.titleLarge?.fontFamily, 'monospace');
      expect(theme.textTheme.labelSmall?.fontFamily, 'monospace');
    });

    test('surfaces are stepped so elevation reads without shadows', () {
      // background < surface < surfaceHigh. Kept as an ordering rather than
      // exact values so the palette can be re-tuned without breaking the
      // relationship the theme depends on.
      double luma(Color c) => c.computeLuminance();

      expect(luma(AppColors.surface), greaterThan(luma(AppColors.background)));
      expect(luma(AppColors.surfaceHigh), greaterThan(luma(AppColors.surface)));
    });
  });

  group('AppColors bubble fills follow the brand', () {
    // Build #100: the bubble fills are tints of the picked brand colour,
    // not hardcoded greens — so the bubbles change with the theme-colour
    // setting. `brand` is global mutable state, so every test here
    // restores it; nothing else in this file may assume it is untouched
    // after this group runs.
    const defaultBrand = Color(0xFF00FF66);

    test('derive from the brand hue, keeping their lightness', () {
      final previous = AppColors.brand;
      try {
        // A blue brand: the bubbles must turn blue too, at the same
        // lightness as the greens they replace.
        AppColors.brand = const Color(0xFF3B82F6);
        final ai = HSLColor.fromColor(AppColors.aiBubble);
        final user = HSLColor.fromColor(AppColors.userBubble);

        expect(ai.hue, closeTo(217.2, 3.0));
        expect(user.hue, closeTo(217.2, 3.0));
        expect(ai.lightness, closeTo(0.10, 0.02));
        expect(user.lightness, closeTo(0.36, 0.02));
        expect(ai.saturation, greaterThan(0.0));
        // Roles stay distinct: the user's bubble is the lighter one.
        expect(
          AppColors.userBubble.computeLuminance(),
          greaterThan(AppColors.aiBubble.computeLuminance()),
        );
      } finally {
        AppColors.brand = previous;
      }
    });

    test('the default brand resolves to the old greens, to a shade', () {
      // The old hardcoded fills, kept as the reference: a user on the
      // default Matrix green must not see the bubbles change at all.
      final previous = AppColors.brand;
      try {
        AppColors.brand = defaultBrand;

        int channel(Color c, int shift) => (c.value >> shift) & 0xFF;
        void expectNear(Color actual, int r, int g, int b) {
          expect(channel(actual, 16), closeTo(r, 5));
          expect(channel(actual, 8), closeTo(g, 5));
          expect(channel(actual, 0), closeTo(b, 5));
        }

        expectNear(AppColors.aiBubble, 18, 32, 21);
        expectNear(AppColors.userBubble, 22, 163, 74);
      } finally {
        AppColors.brand = previous;
      }
    });
  });
}
