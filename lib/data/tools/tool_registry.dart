/// Tool definitions and execution.
///
/// Two rules govern this file, both learned the hard way:
///
/// 1. **A tool may only report [ToolStatus.success] if the operation actually
///    happened.** Seven tools here used to return `{"status":"success"}` while
///    doing nothing, which meant the model would tell the user "your SMS has
///    been sent" when no message existed. Anything not genuinely implemented
///    returns [ToolStatus.unsupported] and is hidden from the model by
///    [toolsForModel], so it is never offered in the first place.
///
/// 2. **Prefer a system Intent that shows the OS confirmation UI over a silent
///    privileged API.** Composing an SMS in the user's own messaging app, or
///    handing an alarm to the clock app, means the user sees exactly what will
///    happen and confirms it themselves. Those tools therefore return
///    [ToolStatus.requiresUserAction] — not success — because at the moment we
///    return, nothing has happened yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/json_extract.dart';
import '../../domain/models/tool_result.dart';
import '../services/connected_apps_store.dart';
import '../services/llm_service.dart';
import '../services/location_weather_service.dart';
import 'tool_permission_store.dart';
import '../database/database_helper.dart';

class ToolRegistry {
  static final ToolRegistry _instance = ToolRegistry._internal();
  factory ToolRegistry() => _instance;
  ToolRegistry._internal();

  final Map<String, ToolDefinition> _tools = {};

  /// Registers every tool definition.
  ///
  /// Call once at startup. Until this runs, [tools] is empty — it previously
  /// never ran at all, so the registry was permanently empty and the agent
  /// silently had no tools.
  void registerTools() {
    void add(ToolDefinition def) => _tools[def.name] = def;

    add(
      ToolDefinition(
        name: 'send_sms',
        description:
            'Compose an SMS to a recipient in the messaging app. The '
            'user must tap send; this does not send anything by itself.',
        parameters: {
          'recipient': {'type': 'string', 'description': 'Phone number'},
          'message': {'type': 'string', 'description': 'Message content'},
        },
        required: ['recipient', 'message'],
        implemented: false,
        unimplementedReason: 'Opens the system SMS composer; not yet wired.',
      ),
    );

    add(
      ToolDefinition(
        name: 'create_calendar_event',
        description: 'Create a calendar event.',
        parameters: {
          'title': {'type': 'string', 'description': 'Event title'},
          'start_time': {
            'type': 'string',
            'description': 'Start time (ISO8601)',
          },
          'end_time': {'type': 'string', 'description': 'End time (ISO8601)'},
          'location': {'type': 'string', 'description': 'Event location'},
        },
        required: ['title', 'start_time'],
        implemented: false,
        unimplementedReason: 'Needs a calendar insert Intent; not yet wired.',
      ),
    );

    add(
      ToolDefinition(
        name: 'add_contact',
        description: 'Add a new contact.',
        parameters: {
          'name': {'type': 'string', 'description': 'Contact name'},
          'phone': {'type': 'string', 'description': 'Phone number'},
          'email': {'type': 'string', 'description': 'Email'},
        },
        required: ['name'],
        implemented: false,
        unimplementedReason: 'Needs a contacts insert Intent; not yet wired.',
      ),
    );

    add(
      ToolDefinition(
        name: 'set_alarm',
        description: 'Set an alarm.',
        parameters: {
          'time': {'type': 'string', 'description': 'Alarm time (ISO8601)'},
          'label': {'type': 'string', 'description': 'Alarm label'},
        },
        required: ['time'],
        implemented: false,
        unimplementedReason: 'Needs the AlarmClock Intent; not yet wired.',
      ),
    );

    add(
      ToolDefinition(
        name: 'open_app',
        description:
            'Open one of the user\'s connected apps by package name. '
            'Only apps the user connected in Settings → Connected apps '
            'can be opened — anything else is refused.',
        parameters: {
          'package_name': {'type': 'string', 'description': 'App package name'},
        },
        required: ['package_name'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'share_to_app',
        description:
            'Send text to one of the user\'s connected apps by package '
            'name, opening that app\'s share screen so the user can '
            'confirm it. Only apps the user connected in Settings → '
            'Connected apps can receive text — anything else is refused.',
        parameters: {
          'package_name': {'type': 'string', 'description': 'App package name'},
          'text': {'type': 'string', 'description': 'Text to send'},
        },
        required: ['package_name', 'text'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'web_search',
        description: 'Search the web with DuckDuckGo.',
        parameters: {
          'query': {'type': 'string', 'description': 'Search query'},
        },
        required: ['query'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'get_location',
        description:
            'Get the device current location: city and temperature. '
            'Use it when asked where the user is or what the weather is.',
        parameters: {},
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'create_note',
        description: 'Save a note on the device.',
        parameters: {
          'title': {'type': 'string', 'description': 'Note title'},
          'content': {'type': 'string', 'description': 'Note content'},
        },
        required: ['title', 'content'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'read_notes',
        description: 'Read notes matching a query.',
        parameters: {
          'query': {'type': 'string', 'description': 'Search query'},
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'analyze_image',
        description:
            'Look at a picture on the device with the local vision '
            'model. Needs a downloaded vision model.',
        parameters: {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the image',
          },
          'question': {'type': 'string', 'description': 'What to ask'},
        },
        required: ['path'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'read_project_file',
        description:
            'Read a text file inside the user\'s Projects folder — the '
            'folder picked in Settings → Projects folder. The path is '
            'relative to that folder, e.g. "lib/main.dart". Use it when '
            'asked about code or files in the project. Nothing outside '
            'the Projects folder can be read.',
        parameters: {
          'path': {
            'type': 'string',
            'description': 'Path relative to the Projects folder',
          },
        },
        required: ['path'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'write_project_file',
        description:
            'Write or create a text file inside the user\'s Projects '
            'folder — the folder picked in Settings → Projects folder. '
            'The path is relative to that folder, e.g. '
            '"lib/main.dart". Parent folders are created as needed. '
            'Nothing outside the Projects folder can be written.',
        parameters: {
          'path': {
            'type': 'string',
            'description': 'Path relative to the Projects folder',
          },
          'content': {
            'type': 'string',
            'description': 'The full text to write into the file',
          },
        },
        required: ['path', 'content'],
        implemented: true,
      ),
    );

    // Tasks and Goals (build #95): Aaron said the Tasks and Goals tabs
    // are for the agent to do, not him. These tools write to the same
    // tables the tabs read, so anything Cypher adds, renames, or ticks
    // off shows up there. A task or goal is found by "id" when the model
    // has one, otherwise by "title" (case-insensitive, exact first,
    // then a unique substring) — the chat only runs one tool round per
    // turn, so a list-then-act round trip is not possible.
    add(
      ToolDefinition(
        name: 'create_task',
        description: 'Add a task to the user\'s Tasks list.',
        parameters: {
          'title': {'type': 'string', 'description': 'Task title'},
        },
        required: ['title'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'list_tasks',
        description:
            'List the user\'s tasks with their ids and whether each '
            'one is done. Use it when asked what tasks exist.',
        parameters: {},
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'update_task',
        description:
            'Rename a task, or mark it done / not done. Find it by '
            '"title" (or "id" when known); "new_title" renames it and '
            '"done" flips its tick.',
        parameters: {
          'id': {'type': 'string', 'description': 'Task id, when known'},
          'title': {
            'type': 'string',
            'description': 'Task title to find, when id is unknown',
          },
          'new_title': {'type': 'string', 'description': 'New title'},
          'done': {'type': 'boolean', 'description': 'True = done'},
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'complete_task',
        description: 'Mark a task done. Find it by "title" (or "id").',
        parameters: {
          'id': {'type': 'string', 'description': 'Task id, when known'},
          'title': {
            'type': 'string',
            'description': 'Task title to find, when id is unknown',
          },
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'delete_task',
        description: 'Delete a task. Find it by "title" (or "id").',
        parameters: {
          'id': {'type': 'string', 'description': 'Task id, when known'},
          'title': {
            'type': 'string',
            'description': 'Task title to find, when id is unknown',
          },
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'create_goal',
        description:
            'Add a goal to the user\'s Goals list. "notes" is what '
            'done looks like, or the next step.',
        parameters: {
          'title': {'type': 'string', 'description': 'Goal title'},
          'notes': {'type': 'string', 'description': 'Notes about the goal'},
        },
        required: ['title'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'list_goals',
        description:
            'List the user\'s goals with their ids, notes, and whether '
            'each one is done. Use it when asked what goals exist.',
        parameters: {},
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'update_goal',
        description:
            'Rename a goal, change its notes, or mark it done / not '
            'done. Find it by "title" (or "id" when known); "new_title" '
            'renames it, "notes" replaces its notes, "done" flips its tick.',
        parameters: {
          'id': {'type': 'string', 'description': 'Goal id, when known'},
          'title': {
            'type': 'string',
            'description': 'Goal title to find, when id is unknown',
          },
          'new_title': {'type': 'string', 'description': 'New title'},
          'notes': {'type': 'string', 'description': 'New notes'},
          'done': {'type': 'boolean', 'description': 'True = done'},
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'complete_goal',
        description: 'Mark a goal done. Find it by "title" (or "id").',
        parameters: {
          'id': {'type': 'string', 'description': 'Goal id, when known'},
          'title': {
            'type': 'string',
            'description': 'Goal title to find, when id is unknown',
          },
        },
        required: const [],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'delete_goal',
        description: 'Delete a goal. Find it by "title" (or "id").',
        parameters: {
          'id': {'type': 'string', 'description': 'Goal id, when known'},
          'title': {
            'type': 'string',
            'description': 'Goal title to find, when id is unknown',
          },
        },
        required: const [],
        implemented: true,
      ),
    );
  }

  /// Every registered definition, implemented or not.
  Map<String, ToolDefinition> get tools => Map.unmodifiable(_tools);

  /// The definitions the model is allowed to see.
  ///
  /// Hiding unimplemented tools is the point: a tool the model can call but
  /// that cannot work produces a confident lie in the final answer.
  List<ToolDefinition> get toolsForModel => _tools.values
      .where((t) => t.implemented && !ToolPermissionStore.isV1Gated(t.name))
      .toList(growable: false);

  bool isImplemented(String toolName) => _tools[toolName]?.implemented ?? false;

  /// The tools section for the chat system prompt, or '' when there is
  /// nothing to offer.
  ///
  /// Lists only [toolsForModel] — never a gated or unimplemented tool —
  /// plus the enabled connected apps with their exact package names, so
  /// the model never has to guess one. The connected-apps gate still
  /// refuses unconnected packages at execution time; this list only tells
  /// the model which packages are valid. Local chat only: the cloud path
  /// never parses tool calls, so a tools section there would only make
  /// the model print raw JSON.
  Future<String> promptSection() async {
    final tools = toolsForModel;
    if (tools.isEmpty) return '';
    final lines = <String>[
      'You can use tools. When the user asks for something a tool can do, '
          'reply with ONLY a JSON block like this and nothing else:',
      '```json',
      '{"tool": "open_app", "params": {"package_name": "com.google.android.youtube"}}',
      '```',
      'Tools:',
      for (final t in tools) '- ${t.name}: ${t.description}',
    ];
    try {
      final enabled = (await ConnectedAppsStore.instance.entries())
          .where((a) => a.enabled)
          .toList();
      if (enabled.isNotEmpty) {
        lines.add(
          'Connected apps you may open or share to — use the package name exactly:',
        );
        for (final a in enabled) {
          lines.add('- ${a.label} (${a.packageName})');
        }
      }
    } catch (_) {
      // No app list is not a reason to hide the tools: the gate still
      // refuses unconnected packages at execution time.
    }
    // Build #100: code Cypher writes must land in the Projects folder, or
    // there is no file to pick it back up from. The rule lives here, in
    // the tools section, because it is about a tool — and because the
    // section is local-only, it never reaches the cloud path (which cannot
    // call tools anyway).
    lines.add(
      'When you write code in a turn — a fenced code block, especially in '
      'code mode — save it with write_project_file so the user keeps it '
      'and you can pick it back up next turn. Pick a sensible filename '
      'from the language and what the code does (for example "hello.dart" '
      'or "todo_app.dart"), relative to the Projects folder. If you are '
      'continuing the file already open in the IDE (shown as "Context '
      'from the open file in the IDE"), write to that same file. Never '
      'silently overwrite an unrelated file: if the name is already taken, '
      'the tool saves it under a distinct name and tells you which — use '
      'the name it reports. Only save code the turn actually produced; '
      'do not write a file on turns with no code.',
    );
    lines.add(
      'If no tool fits the request, answer directly in plain text — do not output a tool block.',
    );
    return lines.join('\n');
  }

  /// Executes a tool.
  ///
  /// [permission] is no longer accepted here — permission is the caller's
  /// decision, enforced by the orchestrator with a real user prompt. A tool
  /// that takes a permission argument it never reads is worse than one that
  /// takes none, because it looks safe.
  Future<ToolResult> executeTool({
    required String toolName,
    required Map<String, dynamic> params,
  }) async {
    final def = _tools[toolName];
    if (def == null) {
      return ToolResult.failed('Unknown tool: $toolName');
    }
    if (ToolPermissionStore.isV1Gated(toolName)) {
      return ToolResult.unsupported(
        '"$toolName" is disabled in Clawzilla v1 (its Android permission '
        'was removed). The tool was not run.',
      );
    }
    if (!def.implemented) {
      return ToolResult.unsupported(
        '${def.unimplementedReason ?? 'Not implemented on this build.'} '
        'The tool was not run.',
      );
    }

    switch (toolName) {
      case 'web_search':
        return _executeWebSearch(params);
      case 'create_note':
        return _executeCreateNote(params);
      case 'read_notes':
        return _executeReadNotes(params);
      case 'get_location':
        return _executeGetLocation(params);
      case 'analyze_image':
        return _executeAnalyzeImage(params);
      case 'open_app':
        return _executeOpenApp(params);
      case 'share_to_app':
        return _executeShareToApp(params);
      case 'read_project_file':
        return _executeReadProjectFile(params);
      case 'write_project_file':
        return _executeWriteProjectFile(params);
      case 'create_task':
        return _executeCreateTask(params);
      case 'list_tasks':
        return _executeListTasks(params);
      case 'update_task':
        return _executeUpdateTask(params);
      case 'complete_task':
        return _executeCompleteTask(params);
      case 'delete_task':
        return _executeDeleteTask(params);
      case 'create_goal':
        return _executeCreateGoal(params);
      case 'list_goals':
        return _executeListGoals(params);
      case 'update_goal':
        return _executeUpdateGoal(params);
      case 'complete_goal':
        return _executeCompleteGoal(params);
      case 'delete_goal':
        return _executeDeleteGoal(params);
      default:
        return ToolResult.unsupported('No implementation for "$toolName".');
    }
  }

  /// The Projects folder, or null when none is picked.
  ///
  /// Read straight from the preferences table — the registry is not a
  /// Riverpod consumer, and this is the same store the settings screen
  /// writes to. An empty string means "removed", same as null.
  Future<String?> _projectsRoot() async {
    final raw =
        await DatabaseHelper.instance.getPreference('projects_folder');
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  /// Resolve [relativePath] inside [root], or null when it escapes.
  ///
  /// Absolute paths and `..` segments are refused: a model that guesses
  /// a path must never reach outside the folder the user pointed at.
  /// Returns the resolved absolute path when it stays inside [root].
  String? _resolveInside(String root, String relativePath) {
    final rel = relativePath.trim();
    if (rel.isEmpty || p.isAbsolute(rel)) return null;
    final resolved = p.normalize(p.join(root, rel));
    if (!p.isWithin(root, resolved)) return null;
    return resolved;
  }

  /// Read a text file inside the Projects folder. Content over the cap
  /// is truncated with a note rather than handed to the model whole —
  /// a small model drowns in a 200 KB file either way.
  static const int _projectReadCap = 50000;

  Future<ToolResult> _executeReadProjectFile(
    Map<String, dynamic> params,
  ) async {
    final rel = (params['path'] as String?)?.trim();
    if (rel == null || rel.isEmpty) {
      return ToolResult.failed(
        'read_project_file requires a "path" relative to the Projects folder.',
      );
    }
    final root = await _projectsRoot();
    if (root == null) {
      return ToolResult.unsupported(
        'No Projects folder is picked yet. Ask the user to pick one in '
        'Settings → Projects folder first.',
      );
    }
    final resolved = _resolveInside(root, rel);
    if (resolved == null) {
      return ToolResult.failed(
        'That path is outside the Projects folder — refused.',
      );
    }
    final file = File(resolved);
    if (!await file.exists()) {
      return ToolResult.failed('No such file in the Projects folder: $rel');
    }
    try {
      final text = await file.readAsString();
      final truncated = text.length > _projectReadCap;
      final shown = truncated
          ? text.substring(0, _projectReadCap)
          : text;
      return ToolResult.success(
        truncated
            ? 'Read $rel (first $_projectReadCap characters — the file is longer).'
            : 'Read $rel.',
        data: {'path': rel, 'content': shown, 'truncated': truncated},
      );
    } catch (e) {
      return ToolResult.failed('Could not read $rel: $e');
    }
  }

  /// Picks a path that does not clobber an existing file, or null when
  /// none is free.
  ///
  /// Build #100: a write to a name that is already taken must never
  /// silently overwrite an unrelated file. The first free name wins:
  /// `main.dart` → `main-2.dart` → `main-3.dart`, and an extensionless
  /// name gets the suffix appended (`README` → `README-2`). Returns
  /// [candidate] unchanged when it is free, and null after 100 tries
  /// with no free name. Pure (the existence check is a parameter) so it
  /// can be unit-tested without touching the disk.
  static String? distinctPath(
    String candidate,
    bool Function(String path) exists,
  ) {
    if (!exists(candidate)) return candidate;
    final dir = p.dirname(candidate);
    final base = p.basename(candidate);
    final ext = p.extension(base);
    final stem =
        ext.isEmpty ? base : base.substring(0, base.length - ext.length);
    for (var i = 2; i <= 100; i++) {
      final next = p.join(dir, '$stem-$i$ext');
      if (!exists(next)) return next;
    }
    return null;
  }

  /// Write a text file inside the Projects folder, creating parent
  /// folders as needed. Content over the cap is refused outright rather
  /// than half-written.
  static const int _projectWriteCap = 200000;

  Future<ToolResult> _executeWriteProjectFile(
    Map<String, dynamic> params,
  ) async {
    final rel = (params['path'] as String?)?.trim();
    if (rel == null || rel.isEmpty) {
      return ToolResult.failed(
        'write_project_file requires a "path" relative to the Projects folder.',
      );
    }
    final content = params['content'] as String?;
    if (content == null) {
      return ToolResult.failed('write_project_file requires "content".');
    }
    if (content.length > _projectWriteCap) {
      return ToolResult.failed(
        'That content is over $_projectWriteCap characters — too big to '
        'write in one go. Split it into smaller files.',
      );
    }
    final root = await _projectsRoot();
    if (root == null) {
      return ToolResult.unsupported(
        'No Projects folder is picked yet. Ask the user to pick one in '
        'Settings → Projects folder first.',
      );
    }
    final resolved = _resolveInside(root, rel);
    if (resolved == null) {
      return ToolResult.failed(
        'That path is outside the Projects folder — refused.',
      );
    }
    // Build #100: never silently overwrite an unrelated file. Writing
    // to the file already open in the IDE is a continuation, so it keeps
    // its name; any other existing file gets a distinct name instead.
    // The actual written path is reported back (relative `path` and
    // absolute `absolutePath`): the chat turns the written file into the
    // open file in the IDE, so the next turn reads it back.
    final active =
        await DatabaseHelper.instance.getPreference('last_ide_file');
    final isContinuation = active != null &&
        active.isNotEmpty &&
        p.normalize(active) == resolved;
    final target = isContinuation
        ? resolved
        : distinctPath(resolved, (path) => File(path).existsSync());
    if (target == null) {
      return ToolResult.failed(
        'That name is taken in the Projects folder and no distinct name '
        'was free. Pick another filename.',
      );
    }
    final targetRel = p.relative(target, from: root);
    try {
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return ToolResult.success(
        'Wrote $targetRel (${content.length} characters).',
        data: {
          'path': targetRel,
          'absolutePath': target,
          'characters': content.length,
        },
      );
    } catch (e) {
      return ToolResult.failed('Could not write $targetRel: $e');
    }
  }

  // ------------------------------------------------------------ tasks/goals
  //
  // Build #95: the Tasks and Goals tabs are for the agent, not the user.
  // These tools write to the same tables the tabs read (insertTask /
  // getTasks / updateTask / setTaskDone / deleteTask and the goal
  // equivalents), so the tabs show Cypher's work with no extra wiring.
  // The tabs re-read on every visit, so a row written here appears
  // there the next time the tab opens.
  //
  // One tool round per turn means the model cannot list first and then
  // act, so update/complete/delete resolve by title as well as id:
  // exact match first (case-insensitive), then a unique substring
  // match. An ambiguous or missing title fails with the candidates
  // listed, so the model asks the user instead of guessing.

  /// Find one row by id or title, or the failure that says why not.
  ({Map<String, dynamic>? row, ToolResult? error}) _resolveRow({
    required List<Map<String, dynamic>> rows,
    required String kind,
    String? id,
    String? title,
  }) {
    if (id != null && id.isNotEmpty) {
      for (final row in rows) {
        if ('${row['id']}' == id) return (row: row, error: null);
      }
      return (
        row: null,
        error: ToolResult.failed('No $kind with id $id.'),
      );
    }
    final needle = title?.trim();
    if (needle == null || needle.isEmpty) {
      return (
        row: null,
        error: ToolResult.failed(
          'Give a $kind "title" or "id" so I know which one.',
        ),
      );
    }
    final lower = needle.toLowerCase();
    final exact = rows
        .where(
          (row) => ('${row['title'] ?? ''}').toLowerCase() == lower,
        )
        .toList();
    if (exact.length == 1) return (row: exact.first, error: null);
    if (exact.length > 1) {
      return (
        row: null,
        error: ToolResult.failed(
          'Several ${kind}s are called "$needle" — say which one by id.',
        ),
      );
    }
    final partial = rows
        .where(
          (row) => ('${row['title'] ?? ''}').toLowerCase().contains(lower),
        )
        .toList();
    if (partial.length == 1) return (row: partial.first, error: null);
    if (partial.isEmpty) {
      return (
        row: null,
        error: ToolResult.failed('No $kind called "$needle".'),
      );
    }
    return (
      row: null,
      error: ToolResult.failed(
        'Several ${kind}s match "$needle": '
        '${partial.map((row) => row['title']).join(', ')} — say which one.',
      ),
    );
  }

  /// A "done" flag from the model: a real bool when the schema is
  /// honoured, a "true"/"false" string when the model writes it as text.
  bool? _doneParam(Map<String, dynamic> params) {
    final raw = params['done'];
    if (raw is bool) return raw;
    if (raw is String) {
      final lower = raw.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return null;
  }

  Future<ToolResult> _executeCreateTask(
    Map<String, dynamic> params,
  ) async {
    final title = (params['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return ToolResult.failed('create_task requires a "title".');
    }
    try {
      final id = const Uuid().v4();
      await DatabaseHelper.instance.insertTask(
        id: id,
        title: title,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      return ToolResult.success(
        'Task added: $title.',
        data: {'id': id, 'title': title},
      );
    } catch (e) {
      return ToolResult.failed('Failed to add task: $e');
    }
  }

  Future<ToolResult> _executeListTasks(
    Map<String, dynamic> params,
  ) async {
    try {
      final tasks = await DatabaseHelper.instance.getTasks();
      final shown = tasks.take(20).toList();
      return ToolResult.success(
        'Found ${shown.length} task(s).',
        data: {
          'tasks': [
            for (final t in shown)
              {
                'id': t['id'],
                'title': t['title'],
                'done': (t['done'] as int? ?? 0) == 1,
              },
          ],
        },
      );
    } catch (e) {
      return ToolResult.failed('Failed to list tasks: $e');
    }
  }

  Future<ToolResult> _executeUpdateTask(
    Map<String, dynamic> params,
  ) async {
    final newTitle = (params['new_title'] as String?)?.trim();
    final done = _doneParam(params);
    if ((newTitle == null || newTitle.isEmpty) && done == null) {
      return ToolResult.failed(
        'update_task needs something to change — "new_title" or "done".',
      );
    }
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'update_task needs a "title" or "id" to find the task.',
      );
    }
    try {
      final tasks = await DatabaseHelper.instance.getTasks();
      final resolved = _resolveRow(
        rows: tasks,
        kind: 'task',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.updateTask(
        id: '${row['id']}',
        title: (newTitle == null || newTitle.isEmpty) ? null : newTitle,
        done: done,
      );
      if (count == 0) {
        return ToolResult.failed('That task is gone — nothing was updated.');
      }
      return ToolResult.success(
        'Task updated: ${newTitle ?? row['title']}.',
        data: {'id': row['id'], 'title': newTitle ?? row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to update task: $e');
    }
  }

  Future<ToolResult> _executeCompleteTask(
    Map<String, dynamic> params,
  ) async {
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'complete_task needs a "title" or "id" to find the task.',
      );
    }
    try {
      final tasks = await DatabaseHelper.instance.getTasks();
      final resolved = _resolveRow(
        rows: tasks,
        kind: 'task',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.setTaskDone(
        id: '${row['id']}',
        done: true,
      );
      if (count == 0) {
        return ToolResult.failed('That task is gone — nothing was done.');
      }
      return ToolResult.success(
        'Marked done: ${row['title']}.',
        data: {'id': row['id'], 'title': row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to complete task: $e');
    }
  }

  Future<ToolResult> _executeDeleteTask(
    Map<String, dynamic> params,
  ) async {
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'delete_task needs a "title" or "id" to find the task.',
      );
    }
    try {
      final tasks = await DatabaseHelper.instance.getTasks();
      final resolved = _resolveRow(
        rows: tasks,
        kind: 'task',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.deleteTask('${row['id']}');
      if (count == 0) {
        return ToolResult.failed('That task is gone already.');
      }
      return ToolResult.success(
        'Deleted task: ${row['title']}.',
        data: {'id': row['id'], 'title': row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to delete task: $e');
    }
  }

  Future<ToolResult> _executeCreateGoal(
    Map<String, dynamic> params,
  ) async {
    final title = (params['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return ToolResult.failed('create_goal requires a "title".');
    }
    final notes = (params['notes'] as String?)?.trim() ?? '';
    try {
      final id = const Uuid().v4();
      await DatabaseHelper.instance.insertGoal(
        id: id,
        title: title,
        notes: notes,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      return ToolResult.success(
        'Goal added: $title.',
        data: {'id': id, 'title': title, 'notes': notes},
      );
    } catch (e) {
      return ToolResult.failed('Failed to add goal: $e');
    }
  }

  Future<ToolResult> _executeListGoals(
    Map<String, dynamic> params,
  ) async {
    try {
      final goals = await DatabaseHelper.instance.getGoals();
      final shown = goals.take(20).toList();
      return ToolResult.success(
        'Found ${shown.length} goal(s).',
        data: {
          'goals': [
            for (final g in shown)
              {
                'id': g['id'],
                'title': g['title'],
                'notes': g['notes'],
                'done': (g['done'] as int? ?? 0) == 1,
              },
          ],
        },
      );
    } catch (e) {
      return ToolResult.failed('Failed to list goals: $e');
    }
  }

  Future<ToolResult> _executeUpdateGoal(
    Map<String, dynamic> params,
  ) async {
    final newTitle = (params['new_title'] as String?)?.trim();
    final notes = (params['notes'] as String?)?.trim();
    final done = _doneParam(params);
    if ((newTitle == null || newTitle.isEmpty) &&
        notes == null &&
        done == null) {
      return ToolResult.failed(
        'update_goal needs something to change — "new_title", "notes", '
        'or "done".',
      );
    }
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'update_goal needs a "title" or "id" to find the goal.',
      );
    }
    try {
      final goals = await DatabaseHelper.instance.getGoals();
      final resolved = _resolveRow(
        rows: goals,
        kind: 'goal',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.updateGoal(
        id: '${row['id']}',
        title: (newTitle == null || newTitle.isEmpty) ? null : newTitle,
        notes: notes,
        done: done,
      );
      if (count == 0) {
        return ToolResult.failed('That goal is gone — nothing was updated.');
      }
      return ToolResult.success(
        'Goal updated: ${newTitle ?? row['title']}.',
        data: {'id': row['id'], 'title': newTitle ?? row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to update goal: $e');
    }
  }

  Future<ToolResult> _executeCompleteGoal(
    Map<String, dynamic> params,
  ) async {
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'complete_goal needs a "title" or "id" to find the goal.',
      );
    }
    try {
      final goals = await DatabaseHelper.instance.getGoals();
      final resolved = _resolveRow(
        rows: goals,
        kind: 'goal',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.updateGoal(
        id: '${row['id']}',
        done: true,
      );
      if (count == 0) {
        return ToolResult.failed('That goal is gone — nothing was done.');
      }
      return ToolResult.success(
        'Marked done: ${row['title']}.',
        data: {'id': row['id'], 'title': row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to complete goal: $e');
    }
  }

  Future<ToolResult> _executeDeleteGoal(
    Map<String, dynamic> params,
  ) async {
    final id = params['id'] as String?;
    final title = params['title'] as String?;
    if ((id == null || id.isEmpty) && (title == null || title.isEmpty)) {
      return ToolResult.failed(
        'delete_goal needs a "title" or "id" to find the goal.',
      );
    }
    try {
      final goals = await DatabaseHelper.instance.getGoals();
      final resolved = _resolveRow(
        rows: goals,
        kind: 'goal',
        id: id,
        title: title,
      );
      if (resolved.error != null) return resolved.error!;
      final row = resolved.row!;
      final count = await DatabaseHelper.instance.deleteGoal('${row['id']}');
      if (count == 0) {
        return ToolResult.failed('That goal is gone already.');
      }
      return ToolResult.success(
        'Deleted goal: ${row['title']}.',
        data: {'id': row['id'], 'title': row['title']},
      );
    } catch (e) {
      return ToolResult.failed('Failed to delete goal: $e');
    }
  }

  /// The native channel MainActivity answers for opening and sharing to
  /// other apps. The Dart side never launches a package on its own —
  /// Android does it, and only for packages on the connected list.
  static const MethodChannel _appsChannel = MethodChannel('clawzilla/apps');

  /// Open a connected app. The package must be on the connected list —
  /// anything else is refused here, before Android is ever asked, so a
  /// model that guesses a package name gets a plain refusal, not a launch.
  /// A store read that fails refuses too: failing closed is the only safe
  /// direction when the gate itself cannot be read.
  Future<ToolResult> _executeOpenApp(Map<String, dynamic> params) async {
    final packageName = params['package_name'] as String?;
    if (packageName == null || packageName.trim().isEmpty) {
      return ToolResult.failed('open_app requires a "package_name".');
    }
    final connected = await _isConnectedApp(packageName);
    if (!connected) {
      return ToolResult.unsupported(
        'That app is not connected. Only apps the user connected in '
        'Settings → Connected apps can be opened.',
      );
    }
    try {
      final opened = await _appsChannel.invokeMethod<bool>(
        'launchApp',
        {'package': packageName},
      );
      if (opened != true) {
        return ToolResult.failed(
          'Could not open that app — it may have been removed.',
        );
      }
      return ToolResult.success('Opened $packageName.');
    } on PlatformException catch (e) {
      return ToolResult.failed('Could not open that app: ${e.message}');
    }
  }

  /// Send text to a connected app. Android opens that app's share screen
  /// with the text already in it — the user sees it and confirms or
  /// cancels there, so nothing is ever sent silently.
  Future<ToolResult> _executeShareToApp(Map<String, dynamic> params) async {
    final packageName = params['package_name'] as String?;
    final text = params['text'] as String?;
    if (packageName == null || packageName.trim().isEmpty) {
      return ToolResult.failed('share_to_app requires a "package_name".');
    }
    if (text == null || text.trim().isEmpty) {
      return ToolResult.failed('share_to_app requires some "text" to send.');
    }
    final connected = await _isConnectedApp(packageName);
    if (!connected) {
      return ToolResult.unsupported(
        'That app is not connected. Only apps the user connected in '
        'Settings → Connected apps can receive text.',
      );
    }
    try {
      final shared = await _appsChannel.invokeMethod<bool>(
        'shareToApp',
        {'package': packageName, 'text': text},
      );
      if (shared != true) {
        return ToolResult.failed(
          'Could not share to that app — it may have been removed.',
        );
      }
      return ToolResult.requiresUserAction(
        'Opened $packageName with the text ready — confirm it there.',
      );
    } on PlatformException catch (e) {
      return ToolResult.failed('Could not share to that app: ${e.message}');
    }
  }

  /// The connected-apps gate, fail-closed: any read failure refuses the
  /// open/share rather than letting it through on an unknown list.
  Future<bool> _isConnectedApp(String packageName) async {
    try {
      return await ConnectedAppsStore.instance.isConnected(packageName);
    } catch (_) {
      return false;
    }
  }

  Future<ToolResult> _executeWebSearch(Map<String, dynamic> params) async {
    final query = params['query'] as String?;
    if (query == null || query.trim().isEmpty) {
      return ToolResult.failed('web_search requires a non-empty "query".');
    }

    try {
      final response = await http
          .get(
            Uri.parse(
              'https://lite.duckduckgo.com/lite/?q=${Uri.encodeComponent(query)}',
            ),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return ToolResult.failed(
          'Search returned HTTP ${response.statusCode}.',
        );
      }

      final results = _parseDuckDuckGoResults(response.body);
      if (results.isEmpty) {
        // The parser targets a specific markup shape. When the page changes we
        // get zero results, and reporting that as an empty-but-successful search
        // let the model answer as if it had searched. Say so instead.
        return ToolResult.unsupported(
          'Could not read any results from the search page — the response '
          'format may have changed. No results were found.',
        );
      }

      return ToolResult.success(
        'Found ${results.length} result(s).',
        data: {'query': query, 'results': results.take(3).toList()},
      );
    } catch (e) {
      return ToolResult.failed('Search failed: $e');
    }
  }

  Future<ToolResult> _executeCreateNote(Map<String, dynamic> params) async {
    final title = (params['title'] as String?)?.trim();
    final content = (params['content'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return ToolResult.failed('create_note requires a non-empty "title".');
    }
    if (content == null || content.isEmpty) {
      return ToolResult.failed('create_note requires a non-empty "content".');
    }
    try {
      final id = Uuid().v4();
      await DatabaseHelper.instance.insertNote(
        id: id,
        title: title,
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      return ToolResult.success(
        'Note saved.',
        data: {'id': id, 'title': title},
      );
    } catch (e) {
      return ToolResult.failed('Failed to save note: $e');
    }
  }

  Future<ToolResult> _executeReadNotes(Map<String, dynamic> params) async {
    final query = (params['query'] as String?)?.trim();
    try {
      final notes = await DatabaseHelper.instance.getNotes(
        query: query == null || query.isEmpty ? null : query,
      );
      final shown = notes.take(10).toList();
      return ToolResult.success(
        'Found ${shown.length} note(s).',
        data: {
          'notes': [
            for (final n in shown)
              {
                'id': n['id'],
                'title': n['title'],
                'content': n['content'],
              },
          ],
        },
      );
    } catch (e) {
      return ToolResult.failed('Failed to read notes: $e');
    }
  }

  Future<ToolResult> _executeGetLocation(Map<String, dynamic> params) async {
    final granted = await Permission.location.request().isGranted;
    if (!granted) {
      return ToolResult.requiresPermission(
        'Location permission was not granted, so the location is unknown.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      // A stale last-known fix is a fix from somewhere else; refuse it
      // rather than reporting the wrong city and temperature.
      if (DateTime.now().difference(position.timestamp) >
          const Duration(minutes: 2)) {
        return ToolResult.failed(
          'Could not get a fresh location fix. Say the location is '
          'unknown rather than guessing.',
        );
      }
      // A raw lat/lon plus a timestamp is what a small model answers with
      // when asked "where am I?" — it reads the timestamp as the location.
      // Hand it the city and the temperature instead, and leave the
      // timestamp out entirely so there is nothing to mistake it for.
      final place = await LocationWeatherService().getLineAt(
        position.latitude,
        position.longitude,
      );
      return ToolResult.success(
        'Location acquired.',
        data: {
          'latitude': position.latitude,
          'longitude': position.longitude,
          if (place != null) 'place': place,
        },
      );
    } catch (e) {
      return ToolResult.failed('Failed to get location: $e');
    }
  }

  /// Run the local vision model over an image already on the device.
  ///
  /// Unlike the stubs above this one is fully implemented — the heavy lifting is
  /// llama.cpp's mtmd path, reached through `LlmService`. It fails loudly rather
  /// than inventing an answer, because a fabricated description of a photo is
  /// worse than no description.
  Future<ToolResult> _executeAnalyzeImage(Map<String, dynamic> params) async {
    final path = params['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.failed('analyze_image requires a "path" parameter.');
    }

    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.failed('Image not found: $path');
    }

    final llm = LlmService.getInstance();
    if (!llm.isLoaded) {
      return ToolResult.unsupported(
        'No model is loaded. Download one in Settings → Models first.',
      );
    }
    if (!llm.isVisionLoaded) {
      return ToolResult.unsupported(
        'No vision model is loaded. Download one in Settings → Models '
        'and pick it as the vision model.',
      );
    }

    final question = (params['question'] as String?)?.trim();
    try {
      final answer = await llm.describeImage(
        path,
        instruction: (question == null || question.isEmpty)
            ? 'Describe this image in detail.'
            : question,
      );
      return ToolResult.success(answer, data: {'result': answer});
    } catch (e) {
      return ToolResult.failed('Vision inference failed: $e');
    }
  }

  List<String> _parseDuckDuckGoResults(String html) {
    final results = <String>[];
    final lines = html.split('\n');

    for (final line in lines) {
      if (line.contains('class="result__a"') ||
          line.contains('result__title')) {
        final start = line.indexOf('>') + 1;
        final end = line.indexOf('<', start);
        if (start > 0 && end > start) {
          results.add(line.substring(start, end).trim());
        }
      }
      if (results.length >= 10) break;
    }

    return results;
  }
}

/// A tool's declared interface.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// Names of parameters the model must supply.
  ///
  /// This used to be derived from a per-parameter `optional` key that no
  /// definition ever set, so `!parameters[k]['optional']` was a null-check on
  /// `null` and building any schema threw. An explicit list cannot be forgotten
  /// into a crash: it is a required constructor argument.
  final List<String> required;

  /// Whether this tool actually works. Unimplemented tools are hidden from the
  /// model entirely.
  final bool implemented;

  final String? unimplementedReason;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    required this.required,
    required this.implemented,
    this.unimplementedReason,
  });

  /// JSON Schema for this tool, built by encoding a real map.
  ///
  /// The previous version interpolated strings directly, so a description
  /// containing a quote produced invalid JSON that the model could not parse.
  /// `jsonEncode` escapes correctly by construction.
  String get schema => jsonEncode({
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': {
        for (final entry in parameters.entries)
          entry.key: {
            'type': (entry.value as Map)['type'],
            'description': (entry.value as Map)['description'],
          },
      },
      'required': required,
    },
  });
}

/// A tool call the model wrote in its reply, or null when there is none.
///
/// Accepts a fenced ```json block or a bare JSON object with a "tool" key,
/// using the same tolerant extractor the planner relies on — a local model
/// rarely returns bare JSON. Never throws: an unparseable reply is a plain
/// answer, not a crash. A call naming an unknown tool is still returned;
/// [ToolRegistry.executeTool] refuses it fail-closed.
({String tool, Map<String, dynamic> params})? parseToolCall(String text) {
  final obj = extractJsonObject(text);
  if (obj == null) return null;
  final tool = obj['tool'];
  if (tool is! String || tool.isEmpty) return null;
  final rawParams = obj['params'];
  final params = rawParams is Map
      ? rawParams.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};
  return (tool: tool, params: params);
}
