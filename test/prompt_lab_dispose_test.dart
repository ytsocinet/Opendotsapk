/// Leaving the Prompt Lab must not throw.
///
/// Regression guard for a real-device crash (build #101): the Lab's
/// dispose safety-net (build #97) called `ref.read(settingsProvider
/// .notifier)` inside `dispose()`, and Riverpod forbids `ref` there —
/// the element is already unmounted — so every exit from the Lab threw
/// `Bad state: Cannot use "ref" after the widget was disposed`.
///
/// The fix captures the notifier in `initState` and defers the save
/// past the frame (build #102): writing provider state from `dispose()`
/// is illegal even through a captured notifier, because the tree is
/// mid-unmount. This pumps the real screen, swaps it away, flushes the
/// deferred save with an extra pump, and asserts both that no error
/// fires and that the dispose save still ran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/core/theme/app_theme.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/screens/prompt_lab_screen.dart';

/// A [SettingsNotifier] that never leaves memory: the real one loads
/// from sqflite and probes connectivity in its constructor, neither of
/// which exists in a widget test. Records every [updateSetting] call so
/// the test can prove the dispose safety-net still ran.
class _FakeSettingsNotifier extends SettingsNotifier {
  _FakeSettingsNotifier() : super.test({});

  final Map<String, dynamic> saved = {};

  @override
  Future<void> updateSetting(String key, dynamic value) async {
    saved[key] = value;
    state = Map<String, dynamic>.from(state)..[key] = value;
  }
}

/// Hosts the Lab below the ProviderScope, so swapping the Lab out —
/// disposing it — does not tear down the scope (and the fake notifier)
/// with it.
class _LabSwapHost extends StatelessWidget {
  const _LabSwapHost({required this.showLab});

  final bool showLab;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.dark,
      home: showLab
          ? const PromptLabScreen()
          : const Scaffold(body: Text('gone')),
    );
  }
}

void main() {
  group('PromptLabScreen dispose', () {
    testWidgets('leaving the Lab saves the parameters without throwing', (
      tester,
    ) async {
      final settings = _FakeSettingsNotifier();
      // One overrides list, reused for both pumps: a fresh list would
      // make the scope rebuild its container, disposing the fake
      // notifier out from under the second tree.
      final overrides = <Override>[
        settingsProvider.overrideWith((ref) => settings),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const _LabSwapHost(showLab: true),
        ),
      );
      await tester.pump();

      expect(find.text('Prompt Lab'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Swap the Lab away: the screen is disposed, which is where the
      // old code called ref.read and threw.
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: const _LabSwapHost(showLab: false),
        ),
      );
      await tester.pump();

      // One more frame: the dispose save is deferred past the frame
      // (build #102 — a post-frame callback), so it only lands on a
      // later pump. Without this the assertions below could run before
      // the save.
      await tester.pump();

      expect(find.text('gone'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'leaving the Lab must not throw: the dispose save is deferred '
            'past the frame, so no provider state may change while the '
            'tree is building or unmounting',
      );

      // And the safety-net still ran: the Lab parameters were persisted
      // through the captured notifier, at their untouched defaults.
      expect(settings.saved['lab_temperature'], 0.7);
      expect(settings.saved['lab_top_k'], 40);
      expect(settings.saved['lab_max_tokens'], 512);
    });
  });
}
