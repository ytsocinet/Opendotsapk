/// Connected apps: the opt-in, off-by-default list of other apps Cypher
/// may open or share to.
///
/// Why a separate store: the list lives in the same settings table as
/// everything else (one persistence system, `connected_apps` key, a JSON
/// list), but the tool layer reads it without going through Riverpod — the
/// registry executes tools outside the widget tree.
///
/// Each entry is `{package, label, enabled}`. Adding an app does NOT
/// enable it: a fresh entry starts disabled, and only an enabled app can
/// be opened or shared to. An empty list means "no app is connected", so
/// nothing is ever opened or shared to without Aaron picking it first in
/// Settings and switching it on.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import '../database/database_helper.dart';

/// One app on the connected list.
class ConnectedAppEntry {
  const ConnectedAppEntry({
    required this.packageName,
    required this.label,
    required this.enabled,
  });

  final String packageName;
  final String label;
  final bool enabled;

  ConnectedAppEntry copyWith({bool? enabled}) => ConnectedAppEntry(
    packageName: packageName,
    label: label,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'package': packageName,
    'label': label,
    'enabled': enabled,
  };

  static ConnectedAppEntry? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final packageName = raw['package'];
    if (packageName is! String || packageName.isEmpty) return null;
    final label = raw['label'];
    return ConnectedAppEntry(
      packageName: packageName,
      label: label is String && label.isNotEmpty ? label : packageName,
      enabled: raw['enabled'] == true,
    );
  }
}

class ConnectedAppsStore {
  static const String _key = 'connected_apps';

  static final ConnectedAppsStore instance = ConnectedAppsStore._();

  ConnectedAppsStore._();

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// The native app picker: Android shows the system list of launchable
  /// apps and returns the one Aaron picked, or null when he backs out.
  /// No permission is needed — the system shows the list, the app only
  /// learns the one package he chose.
  static const MethodChannel _appsChannel = MethodChannel('clawzilla/apps');

  static Future<({String packageName, String label})?> pickApp() async {
    try {
      final result = await _appsChannel
          .invokeMethod<Map<Object?, Object?>>('pickApp');
      if (result == null) return null;
      final packageName = result['package'] as String?;
      if (packageName == null || packageName.isEmpty) return null;
      final label = result['label'] as String?;
      return (
        packageName: packageName,
        label: label ?? packageName,
      );
    } catch (_) {
      return null;
    }
  }

  /// Every entry on the list, enabled or not, in the order added.
  Future<List<ConnectedAppEntry>> entries() async {
    final raw = await _db.getPreference(_key);
    if (raw == null || raw.isEmpty) return <ConnectedAppEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ConnectedAppEntry>[];
      return decoded
          .map(ConnectedAppEntry.fromJson)
          .whereType<ConnectedAppEntry>()
          .toList();
    } catch (_) {
      return <ConnectedAppEntry>[];
    }
  }

  /// The package names Cypher may actually open or share to right now:
  /// only the enabled ones.
  Future<List<String>> list() async {
    final all = await entries();
    return all.where((e) => e.enabled).map((e) => e.packageName).toList();
  }

  /// True when [packageName] is on the list AND switched on.
  Future<bool> isConnected(String packageName) async {
    final all = await entries();
    return all.any((e) => e.packageName == packageName && e.enabled);
  }

  /// Add [packageName] to the list, switched OFF by default. No-op when
  /// it is already there.
  Future<void> add(String packageName, String label) async {
    final all = await entries();
    if (all.any((e) => e.packageName == packageName)) return;
    all.add(
      ConnectedAppEntry(
        packageName: packageName,
        label: label,
        enabled: false,
      ),
    );
    await _save(all);
  }

  /// Switch one entry on or off. No-op when it is not on the list.
  Future<void> setEnabled(String packageName, bool enabled) async {
    final all = await entries();
    final index = all.indexWhere((e) => e.packageName == packageName);
    if (index < 0) return;
    all[index] = all[index].copyWith(enabled: enabled);
    await _save(all);
  }

  /// Remove [packageName] from the list. No-op when it is not there.
  Future<void> remove(String packageName) async {
    final all = await entries();
    final before = all.length;
    all.removeWhere((e) => e.packageName == packageName);
    if (all.length == before) return;
    await _save(all);
  }

  Future<void> _save(List<ConnectedAppEntry> apps) async {
    await _db.savePreference(
      _key,
      jsonEncode(apps.map((e) => e.toJson()).toList()),
    );
  }
}
