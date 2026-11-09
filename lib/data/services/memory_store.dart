/// Memories the user keeps for Cypher, stored on the phone.
///
/// Why a separate store: the Memory screen used to show three hardcoded
/// demo entries ("User is a Binance futures trader" and friends) whose
/// Save and Delete buttons wrote nowhere — the code literally said
/// "In production, update database" and then just closed the dialog.
/// This store is the production backing it never had.
///
/// A memory is a small map: an id, the text, a type
/// ('preference' | 'conversation' | 'profile') and a timestamp
/// (milliseconds since epoch). The list lives in the same settings table
/// as everything else (one persistence system, `user_memories` key, a JSON
/// list), most recent first. It starts empty — nothing is pre-installed
/// here. A bad row is skipped, never allowed to break the list.
library;

import 'dart:convert';

import '../database/database_helper.dart';

class MemoryStore {
  static const String _key = 'user_memories';

  /// Memories accumulate slowly; 100 is roomy without letting the JSON
  /// blob grow unbounded.
  static const int _maxEntries = 100;

  static final MemoryStore instance = MemoryStore._();

  MemoryStore._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Every stored memory, most recent first.
  Future<List<Map<String, dynamic>>> entries() async {
    final raw = await _db.getPreference(_key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final id = row['id'];
        final content = row['content'];
        final type = row['type'];
        final timestamp = row['timestamp'];
        if (id is! String || id.isEmpty) continue;
        if (content is! String || content.isEmpty) continue;
        if (type is! String || type.isEmpty) continue;
        if (timestamp is! int) continue;
        out.add(<String, dynamic>{
          'id': id,
          'content': content,
          'type': type,
          'timestamp': timestamp,
        });
      }
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// Remember [content] as a [type] memory, most recent first.
  Future<void> add(String content, String type) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final all = await entries();
    all.insert(0, <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'content': text,
      'type': type,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (all.length > _maxEntries) {
      all.removeRange(_maxEntries, all.length);
    }
    await _save(all);
  }

  /// Change the text and type of the memory with [id]. No-op when it is
  /// not there. The original timestamp is kept, so an edit does not
  /// pretend the memory is new.
  Future<void> update(String id, String content, String type) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final all = await entries();
    var changed = false;
    for (final row in all) {
      if (row['id'] == id) {
        row['content'] = text;
        row['type'] = type;
        changed = true;
        break;
      }
    }
    if (!changed) return;
    await _save(all);
  }

  /// Forget the memory with [id]. No-op when it is not there.
  Future<void> remove(String id) async {
    final all = await entries();
    final before = all.length;
    all.removeWhere((row) => row['id'] == id);
    if (all.length == before) return;
    await _save(all);
  }

  Future<void> _save(List<Map<String, dynamic>> memories) async {
    await _db.savePreference(_key, jsonEncode(memories));
  }
}
