/// Light/dark mode (build #120): the `theme_mode` setting, the mode
/// parser the app root uses, and the chat tiles rendered in light mode.
///
/// The parser and the theme values are plain `expect` calls — no widget
/// is pumped, no plugin is touched. The tile tests pump real
/// [ChatMessageTile]s under [AppTheme.light] with the same
/// `SettingsNotifier.test` container the TTS tests use, so the settings
/// never leave memory: the real `SettingsNotifier` loads from sqflite in
/// its constructor, which does not exist in a test.
///
/// The tiles carry a 400 ms entrance animation (plus the avatar's
/// forever-repeating pulse), so the harness pumps a fixed 500 ms to
/// settle them instead of `pumpAndSettle`, which would never return.
library;

import 'package:clawzilla/core/theme/app_theme.dart';
import 'package:clawzilla/domain/models/models.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/widgets/chat_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('theme_mode setting', () {
    test('defaults to Dark', () {
      // The default the app root falls back to, and the value the
      // settings defaults carry: a user who set a colour before this
      // setting existed stays on the dark theme they have always had.
      expect(AppTheme.defaultThemeModeSetting, 'dark');
      expect(AppTheme.themeModeFromSetting(null), ThemeMode.dark);
      expect(AppTheme.themeModeFromSetting('dark'), ThemeMode.dark);
    });

    test('parses Light and System', () {
      expect(AppTheme.themeModeFromSetting('light'), ThemeMode.light);
      expect(AppTheme.themeModeFromSetting('system'), ThemeMode.system);
    });

    test('an unrecognised value falls back to Dark', () {
      expect(AppTheme.themeModeFromSetting('bogus'), ThemeMode.dark);
      expect(AppTheme.themeModeFromSetting(''), ThemeMode.dark);
      expect(AppTheme.themeModeFromSetting('Claude'), ThemeMode.dark);
    });
  });

  group('markdown code blocks follow the theme', () {
    test('the code-block fill is light in light mode, dark in dark mode',
        () {
      // The assistant tile renders markdown with
      // `MarkdownStyleSheet.fromTheme(theme)`, so the code-block fill is
      // whatever the theme says — this pins that it really is a light
      // fill under the light theme and a dark fill under the dark one,
      // instead of a hardcoded dark slab on a white page.
      BoxDecoration? decorationFor(ThemeData theme) =>
          MarkdownStyleSheet.fromTheme(theme).codeblockDecoration
              as BoxDecoration?;

      final light = decorationFor(AppTheme.light);
      final dark = decorationFor(AppTheme.dark);
      expect(light, isNotNull);
      expect(dark, isNotNull);
      expect(light!.color, isNotNull);
      expect(dark!.color, isNotNull);
      expect(light.color!.computeLuminance(), greaterThan(0.7));
      expect(dark.color!.computeLuminance(), lessThan(0.3));
    });
  });

  group('ChatMessageTile in light mode', () {
    ProviderContainer containerWith() {
      return ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => SettingsNotifier.test({'time_format': '12h'}),
          ),
          speakingMessageIdProvider.overrideWith((ref) => null),
        ],
      );
    }

    Future<void> pumpTiles(
      WidgetTester tester,
      ProviderContainer container,
      List<ChatMessage> messages, {
      ThemeMode mode = ThemeMode.light,
    }) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: mode,
            home: Scaffold(
              body: Column(
                children: [
                  for (final message in messages)
                    ChatMessageTile(message: message),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    Finder bubbleWith(Color fill) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == fill,
    );

    testWidgets('user bubble is the pale brand tint, AI bubble near-white', (
      tester,
    ) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final user = ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'hello',
        timestamp: DateTime(2026, 11, 18, 14, 30).millisecondsSinceEpoch,
      );
      final assistant = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Hello there',
        timestamp: 0,
      );
      await pumpTiles(tester, container, [user, assistant]);

      // Light fills — not the dark slabs (lightness 0.10/0.36), which
      // would be unreadable dark blobs on the white page.
      expect(
        bubbleWith(AppColors.userBubbleFor(Brightness.light)),
        findsOneWidget,
      );
      expect(
        bubbleWith(AppColors.aiBubbleFor(Brightness.light)),
        findsOneWidget,
      );
      expect(bubbleWith(AppColors.userBubble), findsNothing);
      expect(bubbleWith(AppColors.aiBubble), findsNothing);
    });

    testWidgets('the user timestamp is dark text on the pale bubble', (
      tester,
    ) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final user = ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'hello',
        timestamp: DateTime(2026, 11, 18, 14, 30).millisecondsSinceEpoch,
      );
      await pumpTiles(tester, container, [user]);

      // In dark mode the timestamp is white70 on the strong green
      // bubble; in light mode that white would vanish on the pale tint,
      // so it must be the theme's muted text colour instead.
      final time = tester.widget<Text>(find.text('2:30 PM'));
      expect(
        time.style?.color,
        AppTheme.light.colorScheme.onSurfaceVariant,
      );
    });

    testWidgets('a fenced code block renders in the light tile', (
      tester,
    ) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final assistant = ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'Here is code:\n```dart\nvoid main() {}\n```',
        timestamp: 0,
      );
      await pumpTiles(tester, container, [assistant]);

      expect(find.textContaining('void main'), findsWidgets);
    });

    testWidgets('dark mode still renders the dark fills (control)', (
      tester,
    ) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final user = ChatMessage(
        id: 'u1',
        role: 'user',
        content: 'hello',
        timestamp: 0,
      );
      await pumpTiles(tester, container, [user], mode: ThemeMode.dark);

      expect(bubbleWith(AppColors.userBubble), findsOneWidget);
      expect(
        bubbleWith(AppColors.userBubbleFor(Brightness.light)),
        findsNothing,
      );
    });
  });
}
