/// Auto-reply rules: the per-contact opt-in list (build #123).
///
/// The notifier owns the rules list only. It talks to the database
/// through [AutoReplyStore], so tests use an in-memory fake and never
/// need a real database; the production wiring hands it
/// [DatabaseHelper]. The master toggle, cooldown, and owner's number
/// stay in the settings provider — this file is only the rules table.
///
/// A rule is template-only in Piece A: `mode` is always `'template'`
/// here, and the column exists for Piece B.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database_helper.dart';
import '../../domain/models/auto_reply_rule.dart';
import 'providers.dart';

/// The auto-reply rules, oldest first. Empty until the first load
/// finishes; an empty list after load means Aaron has opted nobody in.
final autoReplyRulesProvider =
    StateNotifierProvider<AutoReplyRulesNotifier, List<AutoReplyRule>>((
      ref,
    ) {
      return AutoReplyRulesNotifier(store: ref.read(databaseProvider));
    });

class AutoReplyRulesNotifier extends StateNotifier<List<AutoReplyRule>> {
  AutoReplyRulesNotifier({required AutoReplyStore store})
    : _store = store,
      super(const []) {
    initialized = _load();
  }

  final AutoReplyStore _store;

  /// Completes when the first load finishes. The provider loads in the
  /// constructor like `SettingsNotifier` does; tests await this instead
  /// of guessing.
  late final Future<void> initialized;

  Future<void> _load() async {
    final rows = await _store.getAutoReplyRules();
    state = rows.map(AutoReplyRule.fromMap).toList();
  }

  /// Reload the list from the database (after an external change, or a
  /// pull to refresh).
  Future<void> refresh() async => _load();

  /// Create a rule. Returns the created rule, with a `rule-<uuid>` id.
  /// The number is stored as Aaron typed it; matching normalises both
  /// sides to digits, so formatting here does not matter.
  Future<AutoReplyRule> createRule({
    required String contactName,
    required String phoneNumber,
    required String templateText,
  }) async {
    final now = DateTime.now();
    final rule = AutoReplyRule(
      id: 'rule-${const Uuid().v4()}',
      contactName: contactName,
      phoneNumber: phoneNumber,
      enabled: true,
      mode: 'template',
      templateText: templateText,
      createdAt: now,
      updatedAt: now,
    );
    await _store.insertAutoReplyRule(rule);
    state = [...state, rule];
    return rule;
  }

  /// Update a rule. Returns false — and changes nothing — for an id
  /// that is not in the list.
  Future<bool> updateRule(AutoReplyRule rule) async {
    final index = state.indexWhere((r) => r.id == rule.id);
    if (index < 0) return false;
    final updated = rule.copyWith(updatedAt: DateTime.now());
    await _store.updateAutoReplyRule(updated);
    final next = [...state];
    next[index] = updated;
    state = next;
    return true;
  }

  /// Toggle one rule on or off. Returns false for an unknown id.
  Future<bool> setRuleEnabled(String id, bool enabled) async {
    final index = state.indexWhere((r) => r.id == id);
    if (index < 0) return false;
    return updateRule(state[index].copyWith(enabled: enabled));
  }

  /// Delete a rule. Returns false — and deletes nothing — for an id
  /// that is not in the list.
  Future<bool> deleteRule(String id) async {
    if (state.indexWhere((r) => r.id == id) < 0) return false;
    await _store.deleteAutoReplyRule(id);
    state = state.where((r) => r.id != id).toList();
    return true;
  }
}
