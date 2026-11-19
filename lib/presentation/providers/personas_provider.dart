/// Personas: one active voice + instruction set for the assistant.
///
/// One persona is active at a time, globally, persisted as the
/// `active_persona_id` setting (default `builtin-cypher`). The active
/// persona's full [Persona.systemPrompt] goes in the personality slot of
/// the system prompt — see `ChatScreenState._buildRequest` — so the model
/// finally sees a sentence ("You are Cypher…") instead of a bare keyword.
///
/// The notifier owns the persona list only. It talks to the database
/// through [PersonaStore], so tests use an in-memory fake and never need
/// a real database; the production wiring hands it [DatabaseHelper].
/// The active id stays in the settings provider — [activePersonaPromptProvider]
/// joins the two, so the chat screen reads one string.
///
/// Built-ins cannot be deleted in v1 (simpler than upstream's
/// delete-then-restore dance, and the default must always exist).
/// Customs can be created, updated, and deleted. No Geoffrey preset:
/// Geoffrey is Shemue-only by Aaron's rule.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database_helper.dart';
import '../../domain/models/persona.dart';
import 'providers.dart';

/// The persona list. Empty until the first load finishes; the notifier
/// seeds the four built-ins when the table is empty.
final personasProvider =
    StateNotifierProvider<PersonasNotifier, List<Persona>>((ref) {
  return PersonasNotifier(store: ref.read(databaseProvider));
});

/// The system-prompt text of the active persona, resolved from the list
/// and the `active_persona_id` setting. Falls back to the Cypher built-in
/// when the stored id is gone — or while the list is still loading — and
/// never rewrites the setting: the fallback is only for prompt
/// resolution.
final activePersonaPromptProvider = Provider<String>((ref) {
  final personas = ref.watch(personasProvider);
  final activeId =
      ref.watch(settingsProvider)['active_persona_id'] as String?;
  return PersonasNotifier.resolveActivePrompt(
    personas: personas,
    activeId: activeId,
  );
});

class PersonasNotifier extends StateNotifier<List<Persona>> {
  PersonasNotifier({required PersonaStore store})
      : _store = store,
        super(const []) {
    initialized = _load();
  }

  final PersonaStore _store;

  /// Completes when the first load (and seed, if the table was empty)
  /// finishes. The provider loads in the constructor like
  /// `SettingsNotifier` does; tests await this instead of guessing.
  late final Future<void> initialized;

  /// The default active persona, and the `active_persona_id` default in
  /// the settings provider.
  static const String defaultPersonaId = 'builtin-cypher';

  /// Cypher's instruction text, also the fallback when the stored active
  /// id matches no persona. Kept as a constant so the fallback never
  /// depends on the database having been seeded.
  static const String cypherSystemPrompt =
      "You are Cypher, Aaron's personal AI assistant. Be concise and accurate.";

  /// The four built-ins, in display order, Cypher first. Fixed
  /// timestamps (not `DateTime.now()`): the seed rows must be identical
  /// on every install, and list order comes from insertion order, not
  /// from these values.
  ///
  /// Coder / Tutor / Writer are adapted from upstream LocalMind's generic
  /// set (Code Assistant / General Tutor / Writing Editor) — useful, no
  /// new concepts.
  static List<Persona> get builtInPersonas {
    final seed = DateTime.utc(2026, 11, 18);
    return [
      Persona(
        id: 'builtin-cypher',
        name: 'Cypher',
        emoji: '🤖',
        systemPrompt: cypherSystemPrompt,
        description: 'Concise, accurate personal assistant.',
        isBuiltIn: true,
        createdAt: seed,
        updatedAt: seed,
      ),
      Persona(
        id: 'builtin-coder',
        name: 'Coder',
        emoji: '💻',
        systemPrompt:
            'You are an expert coding assistant. Help with writing code, '
            'debugging, code reviews, and architecture decisions, and '
            'always show working examples with clear explanations. Follow '
            'best practices and point out pitfalls.',
        description: 'Code, debugging, and reviews with working examples.',
        isBuiltIn: true,
        createdAt: seed,
        updatedAt: seed,
      ),
      Persona(
        id: 'builtin-tutor',
        name: 'Tutor',
        emoji: '📚',
        systemPrompt:
            'You are a patient tutor. Explain topics step by step in simple '
            'terms, using analogies and examples, and break complex ideas '
            'into small pieces. Check understanding by asking questions as '
            'you go, and adapt to the learner\'s level.',
        description: 'Patient, step-by-step explanations for any subject.',
        isBuiltIn: true,
        createdAt: seed,
        updatedAt: seed,
      ),
      Persona(
        id: 'builtin-writer',
        name: 'Writer',
        emoji: '✍️',
        systemPrompt:
            'You are a writing editor. Help produce clear, well-structured '
            'writing: improve drafts, fix grammar, and tighten style while '
            'keeping the author\'s voice. Give specific suggestions with '
            'explanations, and offer alternatives rather than dictating '
            'changes.',
        description: 'Clearer drafts, fixed grammar, kept voice.',
        isBuiltIn: true,
        createdAt: seed,
        updatedAt: seed,
      ),
    ];
  }

  /// The instruction text for [activeId], or the Cypher built-in text
  /// when [activeId] matches no persona (deleted, or never seeded).
  /// Pure: safe to call on an empty list while the first load is still
  /// in flight — the answer is the Cypher text either way.
  static String resolveActivePrompt({
    required List<Persona> personas,
    required String? activeId,
  }) {
    for (final p in personas) {
      if (p.id == activeId) return p.systemPrompt;
    }
    return cypherSystemPrompt;
  }

  /// Load all personas, seeding the built-ins first when the table is
  /// empty (upstream's `seedIfNeeded` pattern). Re-running it is safe:
  /// the seed only fires on an empty table, and the insert replaces by
  /// id.
  Future<void> _load() async {
    var rows = await _store.getPersonas();
    if (rows.isEmpty) {
      for (final p in builtInPersonas) {
        await _store.insertPersona(p);
      }
      rows = await _store.getPersonas();
    }
    state = rows.map(Persona.fromMap).toList();
  }

  /// Create a custom persona. Returns the created persona, with a
  /// `custom-<uuid>` id.
  Future<Persona> createPersona({
    required String name,
    required String emoji,
    required String systemPrompt,
    String? description,
  }) async {
    final now = DateTime.now();
    final persona = Persona(
      id: 'custom-${const Uuid().v4()}',
      name: name,
      emoji: emoji,
      systemPrompt: systemPrompt,
      description: description,
      isBuiltIn: false,
      createdAt: now,
      updatedAt: now,
    );
    await _store.insertPersona(persona);
    state = [...state, persona];
    return persona;
  }

  /// Update a custom persona. Returns false — and changes nothing — for
  /// a built-in or an id that is not in the list.
  Future<bool> updatePersona(Persona persona) async {
    if (persona.isBuiltIn) return false;
    final index = state.indexWhere((p) => p.id == persona.id);
    if (index < 0) return false;
    final updated = persona.copyWith(updatedAt: DateTime.now());
    await _store.updatePersona(updated);
    final next = [...state];
    next[index] = updated;
    state = next;
    return true;
  }

  /// Delete a custom persona. Returns false — and deletes nothing — for
  /// a built-in or an id that is not in the list.
  Future<bool> deletePersona(String id) async {
    Persona? existing;
    for (final p in state) {
      if (p.id == id) existing = p;
    }
    if (existing == null || existing.isBuiltIn) return false;
    await _store.deletePersona(id);
    state = state.where((p) => p.id != id).toList();
    return true;
  }
}
