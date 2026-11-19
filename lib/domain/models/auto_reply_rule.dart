/// An auto-reply rule (build #123, Auto-reply Piece A).
///
/// One row per contact Aaron opted in: a text from that number gets the
/// template reply, once per cooldown window, and only while the master
/// toggle is on. No rule, no reply — that is the safety line, and it is
/// enforced by matching on the sender's number, never by a global switch.
///
/// Storage is one row per rule in the `auto_reply_rules` table (schema
/// v6), plain text like conversation titles — no encryption, unlike
/// message bodies. The incoming message body is never stored anywhere:
/// it is matched on the sender and then dropped. Timestamps are epoch
/// millis, matching every other table in `DatabaseHelper`.
///
/// `mode` exists for Piece B (model-composed replies). Piece A only
/// writes and uses `'template'` — a rule whose mode is anything else is
/// treated as template-only until Piece B lands.
library;

class AutoReplyRule {
  /// Stable id, `rule-<uuid>`.
  final String id;

  /// Display name, e.g. "Shannon". Shown in the rules list; the match
  /// itself is always on [phoneNumber], never on the name.
  final String contactName;

  /// The number to match, as Aaron typed it. Matching normalises both
  /// sides to digits (see [AutoReplyRules] in the service), so "+1 (555)
  /// 123-4567" and "15551234567" are the same rule.
  final String phoneNumber;

  /// Per-rule on/off switch. A disabled rule matches nothing — same
  /// outcome as no rule at all.
  final bool enabled;

  /// Reply mode: `'template'` in Piece A. Piece B adds `'model'`.
  final String mode;

  /// The exact text sent back, word for word. Aaron writes it himself;
  /// the service sends it unchanged.
  final String templateText;

  /// Epoch millis of the last reply sent under this rule, or null when
  /// none has ever been sent. Drives the cooldown guard: one reply per
  /// sender per cooldown window.
  final DateTime? lastRepliedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AutoReplyRule({
    required this.id,
    required this.contactName,
    required this.phoneNumber,
    required this.enabled,
    required this.mode,
    required this.templateText,
    this.lastRepliedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'contact_name': contactName,
      'phone_number': phoneNumber,
      'enabled': enabled ? 1 : 0,
      'mode': mode,
      'template_text': templateText,
      'last_replied_at': lastRepliedAt?.millisecondsSinceEpoch,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory AutoReplyRule.fromMap(Map<String, dynamic> map) {
    final lastRepliedRaw = map['last_replied_at'];
    return AutoReplyRule(
      id: map['id'] as String,
      contactName: (map['contact_name'] as String?) ?? '',
      phoneNumber: (map['phone_number'] as String?) ?? '',
      // sqflite hands back an int for an INTEGER column; a hand-built map
      // in a test may carry a bool instead. Accept both.
      enabled: map['enabled'] == 1 || map['enabled'] == true,
      mode: (map['mode'] as String?) ?? 'template',
      templateText: (map['template_text'] as String?) ?? '',
      lastRepliedAt: lastRepliedRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastRepliedRaw as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  AutoReplyRule copyWith({
    String? id,
    String? contactName,
    String? phoneNumber,
    bool? enabled,
    String? mode,
    String? templateText,
    DateTime? lastRepliedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AutoReplyRule(
      id: id ?? this.id,
      contactName: contactName ?? this.contactName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      templateText: templateText ?? this.templateText,
      lastRepliedAt: lastRepliedAt ?? this.lastRepliedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// The persistence contract the auto-reply service and notifier talk to.
///
/// `DatabaseHelper` implements it; tests use an in-memory fake, so the
/// service never needs a real database to be exercised. Rows are raw maps
/// in the `DatabaseHelper` convention (`getTasks`, `getGoals`, …) — the
/// callers map them through [AutoReplyRule.fromMap]. Preferences ride on
/// the same contract because the background task reads the master toggle,
/// the cooldown and the owner's number straight from the database, with
/// no Riverpod provider in the WorkManager isolate.
abstract class AutoReplyStore {
  /// All rules, oldest first.
  Future<List<Map<String, dynamic>>> getAutoReplyRules();

  /// Insert a rule, replacing any row with the same id.
  Future<void> insertAutoReplyRule(AutoReplyRule rule);

  /// Update a rule's fields. Only the row with [rule]'s id changes.
  Future<void> updateAutoReplyRule(AutoReplyRule rule);

  /// Delete one rule. Returns the number of rows removed (0 or 1).
  Future<int> deleteAutoReplyRule(String id);

  /// One preference, or null when it has never been set.
  Future<String?> getPreference(String key);
}
