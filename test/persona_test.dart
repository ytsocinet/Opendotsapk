/// Build #121: personas — model round-trip, seed-on-empty,
/// delete-custom-only, active-id fallback, prompt-slot order, and a
/// real-database round-trip.
///
/// The notifier tests use an in-memory fake store, so they never touch a
/// real database. The last group opens the real [DatabaseHelper] through
/// `sqflite_common_ffi` (a dev-only dependency): sqflite's platform
/// channel does not exist in a unit test, so the FFI factory stands in
/// for it and the database lands in a temp directory, deleted after
/// every test.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:clawzilla/core/utils/system_prompt.dart';
import 'package:clawzilla/data/database/database_helper.dart';
import 'package:clawzilla/domain/models/persona.dart';
import 'package:clawzilla/presentation/providers/personas_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// In-memory [PersonaStore]: insertion-ordered, no database.
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

Persona _custom({String id = 'custom-1', String name = 'Coach'}) {
  final now = DateTime.utc(2026, 11, 18, 12);
  return Persona(
    id: id,
    name: name,
    emoji: '🏋️',
    systemPrompt: 'Be blunt and direct. No softening, no preamble.',
    description: 'Blunt coaching.',
    isBuiltIn: false,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('Persona model', () {
    test('toMap/fromMap round-trips a custom persona', () {
      final persona = _custom();
      final restored = Persona.fromMap(persona.toMap());
      expect(restored.id, persona.id);
      expect(restored.name, persona.name);
      expect(restored.emoji, persona.emoji);
      expect(restored.systemPrompt, persona.systemPrompt);
      expect(restored.description, persona.description);
      expect(restored.isBuiltIn, isFalse);
      // fromMap rebuilds from epoch millis, which yields a local DateTime;
      // compare the instant, not the zone.
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        persona.createdAt.millisecondsSinceEpoch,
      );
      expect(
        restored.updatedAt.millisecondsSinceEpoch,
        persona.updatedAt.millisecondsSinceEpoch,
      );
    });

    test('toMap/fromMap round-trips a built-in', () {
      final cypher = PersonasNotifier.builtInPersonas.first;
      final restored = Persona.fromMap(cypher.toMap());
      expect(restored.id, 'builtin-cypher');
      expect(restored.isBuiltIn, isTrue);
      expect(restored.description, isNotNull);
    });

    test('timestamps are stored as epoch millis', () {
      final map = _custom().toMap();
      expect(map['created_at'], isA<int>());
      expect(map['updated_at'], isA<int>());
      expect(map['is_built_in'], 0);
      expect(PersonasNotifier.builtInPersonas.first.toMap()['is_built_in'], 1);
    });

    test('copyWith changes only the named fields', () {
      final persona = _custom();
      final renamed = persona.copyWith(name: 'Drill Sergeant');
      expect(renamed.name, 'Drill Sergeant');
      expect(renamed.id, persona.id);
      expect(renamed.systemPrompt, persona.systemPrompt);
      expect(renamed.emoji, persona.emoji);
      expect(renamed.isBuiltIn, persona.isBuiltIn);
      expect(renamed.createdAt, persona.createdAt);
    });
  });

  group('PersonasNotifier with a fake store', () {
    test('seed-on-empty produces exactly the 4 built-ins, Cypher first',
        () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;

      expect(notifier.state.length, 4);
      expect(
        [for (final p in notifier.state) p.id],
        ['builtin-cypher', 'builtin-coder', 'builtin-tutor', 'builtin-writer'],
      );
      expect(
        [for (final p in notifier.state) p.name],
        ['Cypher', 'Coder', 'Tutor', 'Writer'],
      );
      expect(
        [for (final p in notifier.state) p.emoji],
        ['🤖', '💻', '📚', '✍️'],
      );
      expect(notifier.state.every((p) => p.isBuiltIn), isTrue);
      expect(PersonasNotifier.defaultPersonaId, 'builtin-cypher');
      expect(
        notifier.state.first.systemPrompt,
        PersonasNotifier.cypherSystemPrompt,
      );
      expect(
        PersonasNotifier.cypherSystemPrompt,
        "You are Cypher, Aaron's personal AI assistant. "
        'Be concise and accurate.',
      );
    });

    test('a second load does not duplicate the seeds', () async {
      final store = FakePersonaStore();
      final first = PersonasNotifier(store: store);
      await first.initialized;
      final second = PersonasNotifier(store: store);
      await second.initialized;
      expect(second.state.length, 4);
    });

    test('create appends a custom persona', () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;
      final created = await notifier.createPersona(
        name: 'Coach',
        emoji: '🏋️',
        systemPrompt: 'Be blunt and direct.',
        description: 'Blunt coaching.',
      );
      expect(created.id, startsWith('custom-'));
      expect(created.isBuiltIn, isFalse);
      expect(notifier.state.length, 5);
      expect(notifier.state.last, created);
    });

    test('deleting a built-in is refused; deleting a custom works',
        () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;

      expect(await notifier.deletePersona('builtin-cypher'), isFalse);
      expect(notifier.state.length, 4);

      final custom = await notifier.createPersona(
        name: 'Coach',
        emoji: '🏋️',
        systemPrompt: 'Be blunt and direct.',
      );
      expect(await notifier.deletePersona(custom.id), isTrue);
      expect(notifier.state.length, 4);
      expect(
        notifier.state.any((p) => p.id == custom.id),
        isFalse,
      );

      expect(await notifier.deletePersona('no-such-id'), isFalse);
    });

    test('updating a built-in is refused; updating a custom works',
        () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;

      final cypher = notifier.state.first;
      expect(
        await notifier.updatePersona(cypher.copyWith(name: 'Not Cypher')),
        isFalse,
      );
      expect(notifier.state.first.name, 'Cypher');

      final custom = await notifier.createPersona(
        name: 'Coach',
        emoji: '🏋️',
        systemPrompt: 'Be blunt and direct.',
      );
      expect(
        await notifier.updatePersona(custom.copyWith(name: 'Drill Sergeant')),
        isTrue,
      );
      expect(notifier.state.last.name, 'Drill Sergeant');
    });
  });

  group('resolveActivePrompt', () {
    test('falls back to the Cypher text when the stored id is gone',
        () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;

      expect(
        PersonasNotifier.resolveActivePrompt(
          personas: notifier.state,
          activeId: 'custom-deleted-long-ago',
        ),
        PersonasNotifier.cypherSystemPrompt,
      );
      expect(
        PersonasNotifier.resolveActivePrompt(
          personas: notifier.state,
          activeId: null,
        ),
        PersonasNotifier.cypherSystemPrompt,
      );
      // Empty list — e.g. the first load is still in flight — same answer.
      expect(
        PersonasNotifier.resolveActivePrompt(personas: const [], activeId: null),
        PersonasNotifier.cypherSystemPrompt,
      );
    });

    test('returns the matching persona text when the id exists', () async {
      final notifier = PersonasNotifier(store: FakePersonaStore());
      await notifier.initialized;

      final coder =
          notifier.state.firstWhere((p) => p.id == 'builtin-coder');
      expect(
        PersonasNotifier.resolveActivePrompt(
          personas: notifier.state,
          activeId: 'builtin-coder',
        ),
        coder.systemPrompt,
      );

      final custom = await notifier.createPersona(
        name: 'Coach',
        emoji: '🏋️',
        systemPrompt: 'Be blunt and direct.',
      );
      expect(
        PersonasNotifier.resolveActivePrompt(
          personas: notifier.state,
          activeId: custom.id,
        ),
        'Be blunt and direct.',
      );
    });
  });

  group('persona text in the prompt slot', () {
    test('lands after location and before the mode instruction', () {
      const now =
          'Today is Wednesday, November 18, 2026. The current time is 9:00 PM.';
      const location = 'LOCATION: Indianapolis, IN — 45°F, clear.';
      const mode = 'Answer briefly.';
      final coderText = PersonasNotifier.builtInPersonas[1].systemPrompt;

      final prompt = buildSystemPrompt(
        nowLine: now,
        locationLine: location,
        personality: coderText,
        modeInstruction: mode,
      )!;

      expect(prompt, contains(coderText));
      expect(prompt.indexOf(location), lessThan(prompt.indexOf(coderText)));
      expect(prompt.indexOf(coderText), lessThan(prompt.indexOf(mode)));
      // The old bare keyword never appears as the persona text.
      expect(prompt, isNot(contains('professional')));
    });
  });

  group('DatabaseHelper personas (real database)', () {
    setUpAll(() {
      sqfliteFfiInit();
      // Stock Ubuntu ships only the versioned runtime library
      // (`libsqlite3.so.0`); the unversioned `libsqlite3.so` the loader
      // looks for by default exists only with libsqlite3-dev installed.
      // Point the loader at the runtime library so the test works on a
      // plain install — local VM and CI alike.
      databaseFactory = createDatabaseFactoryFfi(ffiInit: () {
        open.overrideFor(
          OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'),
        );
      });
    });

    Future<void> deleteDbFile() async {
      await DatabaseHelper.instance.close();
      final dir = await getDatabasesPath();
      final file = File(p.join(dir, 'clawzilla.db'));
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final sidecar = File('${file.path}$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
    }

    setUp(deleteDbFile);
    tearDown(deleteDbFile);

    test('fresh open creates the personas table; CRUD round-trips',
        () async {
      final db = DatabaseHelper.instance;

      // Fresh database: no personas yet, and the table exists.
      expect(await db.getPersonas(), isEmpty);

      final persona = _custom();
      await db.insertPersona(persona);
      final rows = await db.getPersonas();
      expect(rows.length, 1);
      final restored = Persona.fromMap(rows.first);
      expect(restored.id, persona.id);
      expect(restored.systemPrompt, persona.systemPrompt);
      expect(restored.isBuiltIn, isFalse);

      // Update lands.
      await db.updatePersona(persona.copyWith(name: 'Drill Sergeant'));
      final updated =
          Persona.fromMap((await db.getPersonas()).first);
      expect(updated.name, 'Drill Sergeant');

      // Inserting the same id again replaces instead of duplicating.
      await db.insertPersona(persona);
      expect((await db.getPersonas()).length, 1);

      // Delete removes it.
      expect(await db.deletePersona(persona.id), 1);
      expect(await db.getPersonas(), isEmpty);
      expect(await db.deletePersona(persona.id), 0);
    });

    test('the new table does not disturb existing tables', () async {
      final db = DatabaseHelper.instance;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insertTask(id: 'task-1', title: 'still here', timestamp: now);
      await db.insertPersona(_custom());
      final tasks = await db.getTasks();
      expect(tasks.length, 1);
      expect(tasks.first['title'], 'still here');
      expect((await db.getPersonas()).length, 1);
    });
  });
}
