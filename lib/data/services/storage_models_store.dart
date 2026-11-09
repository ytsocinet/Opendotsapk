/// Models Aaron loaded from storage, kept as slots he can switch between.
///
/// Why a separate store: the list lives in the same settings table as
/// everything else (one persistence system, `storage_models` key, a JSON
/// list of file paths), but the picker reads it without going through
/// Riverpod — the dialog rebuilds from its own state.
///
/// A slot is just a file path. The list starts blank and only grows when
/// a storage load succeeds; Aaron fills it himself, one model at a time.
/// Nothing is pre-installed here — the catalog stays the download list,
/// and these slots are his own models. A path whose file is gone is
/// pruned the next time the picker reads the list.
library;

import 'dart:convert';

import '../database/database_helper.dart';

class StorageModelsStore {
  static const String _key = 'storage_models';

  /// Keep the list short: the picker is for switching, not archiving.
  static const int _maxEntries = 8;

  static final StorageModelsStore instance = StorageModelsStore._();

  StorageModelsStore._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Every stored path, most recently loaded first.
  Future<List<String>> entries() async {
    final raw = await _db.getPreference(_key);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>[];
      return decoded.whereType<String>().where((p) => p.isNotEmpty).toList();
    } catch (_) {
      return <String>[];
    }
  }

  /// Remember [path] as a slot, most recent first. When it is already
  /// there it just moves to the front.
  Future<void> add(String path) async {
    if (path.isEmpty) return;
    final all = await entries();
    all.remove(path);
    all.insert(0, path);
    if (all.length > _maxEntries) all.removeRange(_maxEntries, all.length);
    await _save(all);
  }

  /// Forget [path]. No-op when it is not there.
  Future<void> remove(String path) async {
    final all = await entries();
    final before = all.length;
    all.remove(path);
    if (all.length == before) return;
    await _save(all);
  }

  Future<void> _save(List<String> paths) async {
    await _db.savePreference(_key, jsonEncode(paths));
  }
}
