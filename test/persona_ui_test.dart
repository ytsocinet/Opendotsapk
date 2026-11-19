/// Build #122: Personas Piece B — management UI + header switcher.
///
/// Widget tests for the list screen, the editor, the picker sheet, and
/// the header chip. The header itself cannot be pumped — it lives inside
/// ChatScreen, which pulls in the native llama runtime — so the chip
/// test pumps the public [PersonaChip] directly, the same piece the
/// header renders (the EngineLabel pattern from build #119).
///
/// Everything here stays in memory: the personas come from a fake
/// [PersonaStore] (the Piece A pattern) and the settings from a fake
/// [SettingsNotifier] whose [SettingsNotifier.updateSetting] only
/// updates state — the real one writes to sqflite, which does not
/// exist in a widget test. No `dart:io`, no `path_provider`, no
/// `tester.runAsync` needed.
library;

import 'package:clawzilla/core/theme/app_theme.dart';
import 'package:clawzilla/domain/models/persona.dart';
import 'package:clawzilla/presentation/providers/personas_provider.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/screens/chat_screen.dart';
import 'package:clawzilla/presentation/screens/persona_editor_screen.dart';
import 'package:clawzilla/presentation/screens/personas_screen.dart';
import 'package:clawzilla/presentation/widgets/persona_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [PersonaStore]: insertion-ordered, no database. Same shape
/// as the fake in `test/persona_test.dart`.
class FakePersonaStore implements PersonaStore {
  final Map<String, Persona> _rows = {};

  @override
  Future<List<Map<String, dynamic>>> getPersonas() async =>
      [for (final p in _rows.values) p.toMap()];

  @override
  Future<void> insertPersona(Persona persona) async {
    _rows[persona.id] = persona;
  }

  @override
  Future<void> updatePersona(Persona persona) async {
    _rows[persona.id] = persona;
  }

  @override
  Future<int> deletePersona(String id) async =>
      _rows.remove(id) == null ? 0 : 1;
}

/// A [SettingsNotifier] that never leaves memory: the real
/// `updateSetting` writes the value to sqflite, which does not exist in
/// a widget test. The override keeps the state change (which is what
/// the UI reads) and skips the persistence.
class _FakeSettingsNotifier extends SettingsNotifier {
  _FakeSettingsNotifier()
      : super.test({'active_persona_id': 'builtin-cypher'});

  @override
  Future<void> updateSetting(String key, dynamic value) async {
    state = Map.from(state)..[key] = value;
  }
}

void main() {
  late _FakeSettingsNotifier settings;
  late PersonasNotifier personas;
  late List<Override> overrides;

  /// A notifier seeded with the 4 built-ins, plus a custom "Coach"
  /// when [withCustom] is set. The seed only fires on an empty table,
  /// so the custom is created after the first load finishes.
  Future<void> setUpNotifiers({bool withCustom = false}) async {
    settings = _FakeSettingsNotifier();
    personas = PersonasNotifier(store: FakePersonaStore());
    await personas.initialized;
    if (withCustom) {
      await personas.createPersona(
        name: 'Coach',
        emoji: '🏋️',
        systemPrompt: 'Be blunt and direct. No softening, no preamble.',
        description: 'Blunt coaching.',
      );
    }
    overrides = <Override>[
      personasProvider.overrideWith((ref) => personas),
      settingsProvider.overrideWith((ref) => settings),
    ];
  }

  Future<void> pumpWidget(
    WidgetTester tester,
    Widget child, {
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: theme ?? AppTheme.dark,
          home: child,
        ),
      ),
    );
    await tester.pump();
  }

  /// The editor's ListView, as the drag target for
  /// [WidgetController.dragUntilVisible]. The editor holds several
  /// Scrollables (its ListView, the emoji GridView, each text field's
  /// own), so `scrollUntilVisible`'s default `find.byType(Scrollable)`
  /// matches too many — dragging the ListView itself avoids that.
  final Finder editorList =
      find.byKey(const Key('persona_editor_scroll'));

  /// Scroll [finder] into view, then type into it. The editor's emoji
  /// grid is tall, so the fields below it are not built until the list
  /// scrolls (a lazy viewport only builds what is on screen).
  Future<void> enterField(
    WidgetTester tester,
    String key,
    String value,
  ) async {
    final finder = find.byKey(Key(key));
    await tester.dragUntilVisible(
      finder,
      editorList,
      const Offset(0, -200),
    );
    await tester.enterText(finder, value);
  }
  Widget pickerHost() {
    return Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showPersonaPickerSheet(context),
            child: const Text('Open picker'),
          ),
        ),
      ),
    );
  }

  group('resolveActive', () {
    test('falls back to the Cypher built-in for a gone id', () {
      final active = PersonasNotifier.resolveActive(
        personas: const [],
        activeId: 'custom-deleted',
      );
      expect(active.id, 'builtin-cypher');
      expect(active.name, 'Cypher');
    });

    test('returns the matching persona when the id exists', () {
      final active = PersonasNotifier.resolveActive(
        personas: PersonasNotifier.builtInPersonas,
        activeId: 'builtin-tutor',
      );
      expect(active.name, 'Tutor');
    });
  });

  group('PersonasScreen list', () {
    setUp(() => setUpNotifiers(withCustom: true));

    testWidgets('shows the four built-ins with Built-in labels', (
      tester,
    ) async {
      await pumpWidget(tester, const PersonasScreen());

      expect(find.text('Cypher'), findsOneWidget);
      expect(find.text('Coder'), findsOneWidget);
      expect(find.text('Tutor'), findsOneWidget);
      expect(find.text('Writer'), findsOneWidget);
      expect(find.text('Built-in'), findsNWidgets(4));
      expect(find.text('Concise, accurate personal assistant.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a custom persona', (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      expect(find.text('Coach'), findsOneWidget);
      expect(find.text('Blunt coaching.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a custom persona opens the editor with its values',
        (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.text('Coach'));
      await tester.pumpAndSettle();

      // The name field sits below the emoji grid: scroll to it first,
      // check it, then scroll on to the prompt label.
      await tester.dragUntilVisible(
        find.byKey(const Key('persona_name_field')),
        editorList,
        const Offset(0, -200),
      );
      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('persona_name_field')),
      );
      expect(nameField.controller?.text, 'Coach');
      expect(find.text('Save'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('System prompt'),
        editorList,
        const Offset(0, -200),
      );
      expect(find.text('System prompt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a built-in opens the editor read-only', (
      tester,
    ) async {
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.text('Cypher'));
      await tester.pumpAndSettle();

      expect(
        find.text("Built-in personas can't be edited or deleted."),
        findsOneWidget,
      );
      expect(find.text('Save'), findsNothing);
      await tester.dragUntilVisible(
        find.byKey(const Key('persona_name_field')),
        editorList,
        const Offset(0, -200),
      );
      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('persona_name_field')),
      );
      expect(nameField.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleting a custom persona asks first, then deletes on confirm',
        (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.text('Delete persona?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Coach'), findsNothing);
      expect(find.text('Cypher'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling the delete keeps the persona', (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Coach'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('built-ins offer no delete', (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      // Exactly one delete button: the custom's. The four built-ins
      // carry a "Built-in" label instead.
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // Long-pressing a built-in does nothing — no confirm dialog.
      await tester.longPress(find.text('Cypher'));
      await tester.pump();
      expect(find.text('Delete persona?'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleting the active custom hands the slot back to Cypher',
        (tester) async {
      final coachId =
          personas.state.firstWhere((p) => p.name == 'Coach').id;
      await settings.updateSetting('active_persona_id', coachId);
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Coach'), findsNothing);
      expect(settings.state['active_persona_id'], 'builtin-cypher');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the add button opens a blank editor', (tester) async {
      await pumpWidget(tester, const PersonasScreen());

      await tester.tap(find.byTooltip('New persona'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.byKey(const Key('persona_name_field')),
        editorList,
        const Offset(0, -200),
      );
      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('persona_name_field')),
      );
      expect(nameField.controller?.text, isEmpty);
      await tester.dragUntilVisible(
        find.text('System prompt'),
        editorList,
        const Offset(0, -200),
      );
      expect(find.text('System prompt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('list builds under the light theme', (tester) async {
      await pumpWidget(
        tester,
        const PersonasScreen(),
        theme: AppTheme.light,
      );

      expect(find.text('Cypher'), findsOneWidget);
      expect(find.text('Coach'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('PersonaPickerSheet', () {
    setUp(() => setUpNotifiers(withCustom: true));

    testWidgets('shows every persona with a checkmark on the active one',
        (tester) async {
      await pumpWidget(tester, pickerHost());

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();

      expect(find.text('Switch persona'), findsOneWidget);
      expect(find.text('Cypher'), findsOneWidget);
      expect(find.text('Coder'), findsOneWidget);
      // The checkmark rides on the active (top) row: assert it before
      // scrolling down, which unbuilds the top row.
      expect(find.byIcon(Icons.check), findsOneWidget);
      // Coach is fifth in the sheet: scroll the sheet's list to it.
      await tester.scrollUntilVisible(find.text('Coach'), 100);
      expect(find.text('Coach'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a persona activates it and closes the sheet',
        (tester) async {
      await pumpWidget(tester, pickerHost());

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coder'));
      await tester.pumpAndSettle();

      expect(find.text('Switch persona'), findsNothing);
      expect(settings.state['active_persona_id'], 'builtin-coder');
      expect(tester.takeException(), isNull);
    });
  });

  group('PersonaChip', () {
    setUp(() => setUpNotifiers(withCustom: true));

    testWidgets('shows the active persona name', (tester) async {
      await pumpWidget(tester, const Scaffold(body: PersonaChip()));

      expect(find.text('Cypher'), findsOneWidget);
      expect(find.text('🤖'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap opens the picker and switching updates the chip',
        (tester) async {
      await pumpWidget(tester, const Scaffold(body: PersonaChip()));

      await tester.tap(find.text('Cypher'));
      await tester.pumpAndSettle();
      expect(find.text('Switch persona'), findsOneWidget);

      await tester.tap(find.text('Coder'));
      await tester.pumpAndSettle();

      expect(find.text('Switch persona'), findsNothing);
      expect(find.text('Coder'), findsOneWidget);
      expect(find.text('Cypher'), findsNothing);
      expect(settings.state['active_persona_id'], 'builtin-coder');
      expect(tester.takeException(), isNull);
    });
  });

  group('PersonaEditorScreen', () {
    setUp(() => setUpNotifiers(withCustom: true));

    testWidgets('saving with an empty name shows a validation error',
        (tester) async {
      await pumpWidget(
        tester,
        const Scaffold(body: PersonaEditorScreen()),
      );

      await enterField(
        tester,
        'persona_prompt_field',
        'Be blunt and direct.',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();

      expect(find.text('Give the persona a name.'), findsOneWidget);
      expect(personas.state.length, 5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('saving a new persona creates it', (tester) async {
      await pumpWidget(
        tester,
        const Scaffold(body: PersonaEditorScreen()),
      );

      await enterField(
        tester,
        'persona_name_field',
        'Drill Sergeant',
      );
      await enterField(
        tester,
        'persona_prompt_field',
        'Be blunt and direct. No softening, no preamble.',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        personas.state.any((p) => p.name == 'Drill Sergeant'),
        isTrue,
      );
      expect(
        personas.state
            .firstWhere((p) => p.name == 'Drill Sergeant')
            .isBuiltIn,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a system prompt past 1000 chars shows a length warning',
        (tester) async {
      await pumpWidget(
        tester,
        const Scaffold(body: PersonaEditorScreen()),
      );

      await enterField(
        tester,
        'persona_prompt_field',
        'x' * 1001,
      );
      await tester.pump();
      // The warning sits just below the prompt field: scroll to it.
      await tester.dragUntilVisible(
        find.textContaining('Long prompt'),
        editorList,
        const Offset(0, -200),
      );

      expect(find.textContaining('Long prompt'), findsOneWidget);
      expect(find.textContaining('1001 characters'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing a custom persona updates its name', (
      tester,
    ) async {
      final coach =
          personas.state.firstWhere((p) => p.name == 'Coach');
      await pumpWidget(
        tester,
        Scaffold(body: PersonaEditorScreen(persona: coach)),
      );

      await enterField(
        tester,
        'persona_name_field',
        'Head Coach',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        personas.state.any((p) => p.name == 'Head Coach'),
        isTrue,
      );
      expect(
        personas.state.any((p) => p.name == 'Coach'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
