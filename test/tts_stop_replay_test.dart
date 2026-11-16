/// Stop / replay for the voice bubble (build #107).
///
/// Regression guard for Aaron's report that he "can't stop her from
/// talking, replay doesn't work, the stop button's sticking": the bubble's
/// stop icon only called the engine's `stop()`, and the speaking id only
/// cleared when the cancelled `speak()` returned — which never happened
/// when the engine skipped its cancel handler, so the icon stayed stuck
/// until the duration-estimate cap (up to 120s) and a replay queued
/// behind a dead wait.
///
/// The fix has two halves, and both are pinned here:
///   - `TtsNotifier.stop()` completes the pending `speak()` completer, so
///     the awaiting `speak()` returns at once instead of waiting out the
///     cap;
///   - the bubble's `_stopSpeaking` clears the speaking id synchronously
///     on tap, so the icon flips back to replay immediately.
///
/// The engine is faked with a mock method-channel handler that answers
/// every call but never reports completion back — the exact engine
/// behaviour that left the icon stuck. No existing test touches
/// `FlutterTts`, so there was no fake to reuse; the mock follows the
/// `MethodChannel('flutter_tts')` pattern other projects use for this
/// plugin.
library;

import 'dart:async';

import 'package:clawzilla/core/theme/app_theme.dart';
import 'package:clawzilla/domain/models/models.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/widgets/chat_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for the native TTS engine: answers every method call, but
/// never fires a completion, cancel, or error callback — the engine
/// behaviour that left the stop icon stuck. Records each `speak` call's
/// text so tests can prove a replay actually re-spoke, and signals when
/// the first `speak` has reached the engine, so a test only stops once
/// the notifier is parked on its completer.
class _SilentTtsEngine {
  final List<String> spoken = [];
  final Completer<void> speakStarted = Completer<void>();

  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'speak':
        final args = call.arguments;
        if (args is Map) {
          spoken.add(args['text']?.toString() ?? '');
        } else {
          spoken.add(args?.toString() ?? '');
        }
        if (!speakStarted.isCompleted) speakStarted.complete();
        return 1;
      case 'getVoices':
        return <dynamic>[];
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ttsChannel = MethodChannel('flutter_tts');
  late _SilentTtsEngine engine;

  setUp(() {
    engine = _SilentTtsEngine();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, engine.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  /// A container whose settings never leave memory: the real
  /// `SettingsNotifier` loads from sqflite in its constructor, which
  /// does not exist in a test. Same `SettingsNotifier.test` pattern as
  /// the Prompt Lab dispose test.
  ProviderContainer containerWith({String? speakingId}) {
    return ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => SettingsNotifier.test({
            'tts_pitch': 1.0,
            'tts_voice': '',
            'time_format': '12h',
          }),
        ),
        speakingMessageIdProvider.overrideWith((ref) => speakingId),
      ],
    );
  }

  Future<void> pumpTiles(
    WidgetTester tester,
    ProviderContainer container,
    List<ChatMessage> messages,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark,
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
    // Let the tile's entrance finish before any tap: the tile scales in
    // over 400 ms (plus a 400 ms fade), and a zero-duration pump does not
    // advance the fake clock, so after pumpWidget alone the tile is still
    // ~0 scale and its stop/replay button does not hit-test — taps miss
    // (failure 2). A fixed 500 ms pump settles it. Not pumpAndSettle:
    // the avatar's pulse animation repeats forever, so pumpAndSettle
    // would never return.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  group('TtsNotifier.stop', () {
    test('stop() releases a parked speak() instead of waiting out the cap',
        () async {
      final container = containerWith();
      addTearDown(container.dispose);
      final tts = container.read(textToSpeechProvider.notifier);

      // One word caps at 4s (1 / 2.5 + 3s); the test only allows 2s, so
      // a pass proves stop() released the wait instead of the cap
      // expiring.
      final speaking = tts.speak('hello');
      await engine.speakStarted.future;
      await tts.stop();
      await expectLater(
        speaking.timeout(const Duration(seconds: 2)),
        completes,
      );
    });

    test('stop() with nothing speaking is a no-op', () async {
      final container = containerWith();
      addTearDown(container.dispose);
      final tts = container.read(textToSpeechProvider.notifier);

      await tts.stop();
      expect(engine.spoken, isEmpty);
    });

    test('a speak() started after stop() parks on its own completer',
        () async {
      final container = containerWith();
      addTearDown(container.dispose);
      final tts = container.read(textToSpeechProvider.notifier);

      final first = tts.speak('first answer');
      await engine.speakStarted.future;
      await tts.stop();
      await expectLater(
        first.timeout(const Duration(seconds: 2)),
        completes,
      );

      // The replay: a fresh speak() after the stop. If the first
      // utterance's completer were still filed as pending, this stop
      // would complete the dead one and the replay would hang until its
      // cap — so this stop must release the new speak, not the old one.
      final second = tts.speak('second answer');
      await tts.stop();
      await expectLater(
        second.timeout(const Duration(seconds: 2)),
        completes,
      );
      expect(engine.spoken, ['first answer', 'second answer']);
    });
  });

  group('ChatMessageTile stop / replay', () {
    testWidgets('tapping stop clears the speaking id at once', (
      tester,
    ) async {
      final container = containerWith(speakingId: 'msg-1');
      addTearDown(container.dispose);
      final message = ChatMessage(
        id: 'msg-1',
        role: 'assistant',
        content: 'Hello there',
        timestamp: 0,
      );
      await pumpTiles(tester, container, [message]);

      expect(find.byTooltip('Stop voice'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop voice'));
      await tester.pump();

      // Flips back immediately — the old code waited for the cancelled
      // speak() to return, which never happened on a silent engine.
      expect(container.read(speakingMessageIdProvider), isNull);
      expect(find.byTooltip('Replay answer'), findsOneWidget);
      expect(find.byTooltip('Stop voice'), findsNothing);
    });

    testWidgets('stop then replay re-speaks the same answer', (
      tester,
    ) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final tts = container.read(textToSpeechProvider.notifier);
      final message = ChatMessage(
        id: 'msg-1',
        role: 'assistant',
        content: 'Hello there',
        timestamp: 0,
      );

      // The stuck state, reproduced: an utterance is playing (parked on
      // its completer, engine silent) and this bubble is the speaking one.
      final first = tts.speak('Hello there');
      var firstDone = false;
      unawaited(first.then((_) => firstDone = true));
      await engine.speakStarted.future;
      container.read(speakingMessageIdProvider.notifier).state = 'msg-1';
      await pumpTiles(tester, container, [message]);

      await tester.tap(find.byTooltip('Stop voice'));
      await tester.pump();
      await tester.pump();
      expect(container.read(speakingMessageIdProvider), isNull);
      expect(firstDone, isTrue);

      await tester.tap(find.byTooltip('Replay answer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(speakingMessageIdProvider), 'msg-1');
      expect(engine.spoken, ['Hello there', 'Hello there']);

      // Release the replay so nothing dangles: the replay's guard clears
      // the id once its speak returns. stop() only releases a speak that
      // has already filed its completer — if it runs before the replay's
      // speak() files _pendingDone, the replay parks on its 4s
      // duration-estimate cap instead ('Hello there' is 2 words: 1 + 3s).
      // Pumping past the cap is the backstop either way, so the replay
      // always returns and clears the id: the test never depends on which
      // side of that race wins, and no parked speak (pending fake timer)
      // survives to the post-test invariant check.
      await tts.stop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(container.read(speakingMessageIdProvider), isNull);
    });

    testWidgets('replay on another bubble stops the current utterance first',
        (tester) async {
      final container = containerWith();
      addTearDown(container.dispose);
      final tts = container.read(textToSpeechProvider.notifier);
      final firstMessage = ChatMessage(
        id: 'msg-1',
        role: 'assistant',
        content: 'First answer',
        timestamp: 0,
      );
      final secondMessage = ChatMessage(
        id: 'msg-2',
        role: 'assistant',
        content: 'Second answer',
        timestamp: 0,
      );

      final first = tts.speak('First answer');
      var firstDone = false;
      unawaited(first.then((_) => firstDone = true));
      await engine.speakStarted.future;
      container.read(speakingMessageIdProvider.notifier).state = 'msg-1';
      await pumpTiles(tester, container, [firstMessage, secondMessage]);

      expect(find.byTooltip('Stop voice'), findsOneWidget);
      expect(find.byTooltip('Replay answer'), findsOneWidget);

      await tester.tap(find.byTooltip('Replay answer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The first utterance was released at once — not after its 4s cap —
      // and the second bubble is now the speaking one.
      expect(firstDone, isTrue);
      expect(container.read(speakingMessageIdProvider), 'msg-2');
      expect(engine.spoken, ['First answer', 'Second answer']);

      // Same release as the stop-then-replay test: stop() releases the
      // replay only if its speak already filed its completer; the 5s pump
      // fires the replay's 4s cap as a backstop ('Second answer' is also
      // 2 words), so the id clears either way and no parked speak survives.
      await tts.stop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(container.read(speakingMessageIdProvider), isNull);
    });
  });
}
