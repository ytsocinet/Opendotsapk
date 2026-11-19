/// Tapping the ENGINE line in the chat header opens the Cloud Models screen.
///
/// Regression guard for build #119: the providers used to be reachable only
/// through Settings → Cloud Integration. The ENGINE label is now tappable
/// and jumps straight to the Cloud Models screen, so Aaron can get to the
/// providers in one tap from chat.
///
/// The header itself cannot be pumped — it lives inside ChatScreen, which
/// pulls in the native llama runtime — so this pumps the public
/// [EngineLabel] widget directly, the same piece the header renders.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/core/theme/app_theme.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/screens/chat_screen.dart';

/// A [SettingsNotifier] that never leaves memory: the real one loads from
/// sqflite, which does not exist in a widget test. The Cloud Models screen
/// only reads settings on build, so an empty map is enough.
class _FakeSettingsNotifier extends SettingsNotifier {
  _FakeSettingsNotifier() : super.test({});
}

void main() {
  group('EngineLabel providers shortcut (build #119)', () {
    late _FakeSettingsNotifier settings;
    late List<Override> overrides;

    setUp(() {
      settings = _FakeSettingsNotifier();
      overrides = <Override>[
        settingsProvider.overrideWith((ref) => settings),
      ];
    });

    Future<void> pumpLabel(WidgetTester tester, String label) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(body: EngineLabel(label: label)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('tapping a cloud ENGINE label opens Cloud Models', (
      tester,
    ) async {
      await pumpLabel(tester, 'ENGINE: OpenRouter · openai/gpt-4o');

      expect(find.text('ENGINE: OpenRouter · openai/gpt-4o'), findsOneWidget);
      expect(find.text('Cloud Models'), findsNothing);

      await tester.tap(find.text('ENGINE: OpenRouter · openai/gpt-4o'));
      await tester.pumpAndSettle();

      expect(find.text('Cloud Models'), findsOneWidget);
      // The Providers section sits below the privacy and routing cards, so
      // the ListView only builds it once it is scrolled into view.
      await tester.scrollUntilVisible(find.text('Providers'), 300);
      await tester.pumpAndSettle();
      expect(find.text('Providers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an On-device ENGINE label opens Cloud Models too', (
      tester,
    ) async {
      await pumpLabel(tester, 'ENGINE: On-device · gemma-3-1b');

      await tester.tap(find.text('ENGINE: On-device · gemma-3-1b'));
      await tester.pumpAndSettle();

      expect(find.text('Cloud Models'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
