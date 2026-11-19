/// A persona: a named voice + instruction text for the assistant.
///
/// A persona is voice + instructions, not a model: which model answers is
/// picked separately (My Models / Change model), and generation parameters
/// live in Prompt Lab, not here. One persona is active at a time, globally,
/// persisted as the `active_persona_id` setting — see
/// [PersonasNotifier] in `lib/presentation/providers/personas_provider.dart`.
///
/// Storage is one row per persona in the `personas` table (schema v5), plain
/// text like conversation titles — no encryption, unlike message bodies.
/// Timestamps are epoch millis, matching every other table in
/// `DatabaseHelper`.
library;

class Persona {
  /// Stable id, persisted in the `active_persona_id` setting. Built-ins
  /// use `builtin-…` ids so a stored active id survives an app update;
  /// customs use `custom-<uuid>`.
  final String id;

  /// Display name, e.g. "Cypher".
  final String name;

  /// The avatar — an emoji, shown in the list and (Piece B) the header chip.
  final String emoji;

  /// The full instruction text that goes in the personality slot of the
  /// system prompt. This is the whole point of a persona: the model sees
  /// this sentence, not a bare keyword.
  final String systemPrompt;

  /// One short line shown under the name in the list. Null means none.
  final String? description;

  /// Built-ins ship with the app and cannot be deleted in v1; customs can.
  final bool isBuiltIn;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Persona({
    required this.id,
    required this.name,
    required this.emoji,
    required this.systemPrompt,
    this.description,
    required this.isBuiltIn,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'emoji': emoji,
      'system_prompt': systemPrompt,
      'description': description,
      'is_built_in': isBuiltIn ? 1 : 0,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Persona.fromMap(Map<String, dynamic> map) {
    return Persona(
      id: map['id'] as String,
      name: map['name'] as String,
      emoji: map['emoji'] as String,
      systemPrompt: map['system_prompt'] as String,
      description: map['description'] as String?,
      // sqflite hands back an int for an INTEGER column; a hand-built map
      // in a test may carry a bool instead. Accept both.
      isBuiltIn: map['is_built_in'] == 1 || map['is_built_in'] == true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  Persona copyWith({
    String? id,
    String? name,
    String? emoji,
    String? systemPrompt,
    String? description,
    bool? isBuiltIn,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Persona(
      id: id ?? this.id,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      description: description ?? this.description,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// The persistence contract the personas notifier talks to.
///
/// `DatabaseHelper` implements it; tests use an in-memory fake, so the
/// notifier never needs a real database to be exercised. Rows are raw maps
/// in the `DatabaseHelper` convention (`getTasks`, `getGoals`, …) — the
/// notifier maps them through [Persona.fromMap].
abstract class PersonaStore {
  /// All personas, in insertion order (built-ins first, then customs in
  /// the order they were created).
  Future<List<Map<String, dynamic>>> getPersonas();

  /// Insert a persona, replacing any row with the same id — re-seeding is
  /// safe to repeat.
  Future<void> insertPersona(Persona persona);

  /// Update a persona's fields. Only the row with [persona]'s id changes.
  Future<void> updatePersona(Persona persona);

  /// Delete one persona. Returns the number of rows removed (0 or 1).
  Future<int> deletePersona(String id);
}
