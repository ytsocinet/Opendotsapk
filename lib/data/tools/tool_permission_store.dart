/// Single source of truth for what each tool is allowed to do.
///
/// Before this existed there were two of these: a private map inside
/// `ToolRegistry` and a separate `PermissionsNotifier` in the UI layer. They
/// never spoke, so changing a permission in Settings did not change what the
/// agent did, and nothing survived a restart because the notifier's loader
/// never read anything back.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/log.dart';

enum ToolPermission {
  allow,
  ask,
  block;

  String get wire => name;

  static ToolPermission parse(String? value) {
    return switch (value) {
      'allow' => ToolPermission.allow,
      'block' => ToolPermission.block,
      _ => ToolPermission.ask,
    };
  }
}

class ToolPermissionStore {
  static const _prefix = 'tool_permission.';

  /// Tools whose Android permissions were removed in Clawzilla v1.
  /// These are always Block, regardless of stored or requested values.
  ///
  /// `open_app` is NOT here any more: it left the gate when connected
  /// apps landed (Nov 7, 2026). It is gated per-app instead — the model
  /// may only open an app Aaron picked in Settings → Connected apps, and
  /// the registry refuses anything else at execution time.
  ///
  /// `get_location` is NOT here any more either: it left the gate when
  /// Aaron approved live location (Nov 11, 2026) so the model can know
  /// where he is and the temperature. It defaults to ask, and the
  /// location permission itself is requested at runtime.
  ///
  /// The last four — send_sms, create_calendar_event, add_contact,
  /// set_alarm — left the gate in build #110 (Nov 16, 2026), when Aaron
  /// approved them all and chose silent execution ("I want Cypher to
  /// send, no tap for me"). They are NOT in [silentTools] by accident:
  /// see below. The gate itself is kept empty rather than deleted: if a
  /// tool ever needs gating again, adding its name back here re-blocks
  /// it everywhere (model list, execution, Tools screen) in one place.
  static const Set<String> v1GatedTools = {};

  static bool isV1Gated(String toolName) => v1GatedTools.contains(toolName);

  /// Tools that run silently: no in-app ask prompt, no system UI to
  /// confirm in. Aaron chose this explicitly (Nov 16, 2026, build #110)
  /// for all four — he wants Cypher to send the SMS, create the event,
  /// add the contact, and set the alarm with no tap from him.
  ///
  /// The risk is stated here on purpose, not hidden: with no
  /// confirmation step, a wrong recipient or a wrong time goes out
  /// exactly as the model called it. The registry guards this the only
  /// way it can — a tool reports success only when the write actually
  /// happened, and a failure reports clearly — but it cannot catch a
  /// wrong-but-valid call. Aaron can flip any of these back to ask (or
  /// block) on the Tools screen; a stored value is respected over this
  /// default (see [load]).
  static const Set<String> silentTools = {
    'send_sms',
    'create_calendar_event',
    'add_contact',
    'set_alarm',
  };

  static bool isSilent(String toolName) => silentTools.contains(toolName);

  final Map<String, ToolPermission> _cache = {};

  /// Every tool starts at [ToolPermission.ask] — except the four in
  /// [silentTools], which start at [ToolPermission.allow] by Aaron's
  /// explicit choice (Nov 16, 2026): he wants no tap for those.
  ///
  /// Not `allow` generally: a default of allow means a fresh install
  /// silently executes whatever the model decides to call. `ask` costs
  /// one tap and is the only honest default when the action leaves the
  /// device (SMS, contacts) or reveals where the user is — unless the
  /// user has said otherwise for that tool, which Aaron has for the
  /// silent four.
  static ToolPermission defaultFor(String toolName) {
    if (isV1Gated(toolName)) return ToolPermission.block;
    if (isSilent(toolName)) return ToolPermission.allow;
    return ToolPermission.ask;
  }

  /// Reads persisted permissions. Unknown tools keep the default.
  Future<void> load(Iterable<String> toolNames) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final name in toolNames) {
        final raw = prefs.getString('$_prefix$name');
        _cache[name] = raw == null
            ? defaultFor(name)
            : ToolPermission.parse(raw);
        // A permission granted before the v1 trim must not survive it.
        if (isV1Gated(name)) _cache[name] = ToolPermission.block;
      }
    } catch (e) {
      // A read failure must not leave a tool unrestricted. Falling back to the
      // defaults (all `ask`) is the safe direction: worst case the user is
      // prompted more often than necessary.
      Log.w('ToolPermissionStore.load failed, defaulting to "ask": $e');
      for (final name in toolNames) {
        _cache.putIfAbsent(name, () => defaultFor(name));
      }
    }
  }

  ToolPermission get(String toolName) =>
      _cache[toolName] ?? defaultFor(toolName);

  Map<String, ToolPermission> get all => Map.unmodifiable(_cache);

  Future<void> set(String toolName, ToolPermission permission) async {
    final effective =
        isV1Gated(toolName) ? ToolPermission.block : permission;
    _cache[toolName] = effective;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$toolName', effective.wire);
    } catch (e) {
      // Keep the in-memory value: the session should honour the change even if
      // persistence failed, and the caller is told via the return of the UI.
      // Logged, because "I allowed this tool and it still asks me every time"
      // is a support question with no other visible cause.
      Log.w(
        'ToolPermissionStore: could not persist "$toolName" → '
        '${effective.wire}; it applies to this session only: $e',
      );
    }
  }
}
