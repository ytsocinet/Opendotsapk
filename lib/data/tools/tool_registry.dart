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
///
///    Exception, Nov 16, 2026 (build #110): Aaron explicitly overrode this
///    rule for send_sms, create_calendar_event, add_contact, and set_alarm
///    — "I want Cypher to send, no tap for me." Those four use silent
///    privileged APIs (SmsManager, ContentResolver, AlarmManager), default
///    to allow with no ask prompt ([ToolPermissionStore.silentTools]), and
///    report [ToolStatus.success] only when the write actually happened.
///    The risk stands and is recorded in the permission store: with no
///    confirmation step, a wrong recipient or a wrong time goes out as-is.
///    Everything else in this file still follows rule 2.
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
import '../../core/utils/log.dart';
import '../../domain/models/tool_result.dart';
import '../services/browser_driver.dart';
import '../services/connected_apps_store.dart';
import '../services/llm_service.dart';
import '../services/location_weather_service.dart';
import 'tool_permission_store.dart';
import '../database/database_helper.dart';

/// What the cloud follow-up does with one tool call from a cloud reply.
///
/// See [ToolRegistry.decideCloudCall].
enum CloudToolDecision {
  /// Run the tool now.
  run,

  /// Show Aaron the confirmation dialog first; run only if he approves.
  ask,

  /// Refuse without running: the tool is Blocked in Settings → Tools.
  refuseBlocked,

  /// Not a cloud tool: never execute; the reply stays a plain answer.
  notAllowed,
}

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
            'Send an SMS to a phone number or a contact name right now, '
            'with no confirmation. Only use when the user asked for a '
            'message to be sent.',
        parameters: {
          'recipient': {
            'type': 'string',
            'description': 'Phone number, or a contact name to look up',
          },
          'message': {'type': 'string', 'description': 'Message content'},
        },
        required: ['recipient', 'message'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'create_calendar_event',
        description:
            'Create a calendar event right now, with no confirmation. '
            'Only use when the user asked for an event to be added.',
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
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'add_contact',
        description:
            'Add a new contact right now, with no confirmation. Only use '
            'when the user asked for a contact to be saved.',
        parameters: {
          'name': {'type': 'string', 'description': 'Contact name'},
          'phone': {'type': 'string', 'description': 'Phone number'},
          'email': {'type': 'string', 'description': 'Email'},
        },
        required: ['name'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'set_alarm',
        description:
            'Set an alarm that rings on this phone right now, with no '
            'confirmation. Time is HH:MM or ISO8601. Only use when the '
            'user asked for an alarm.',
        parameters: {
          'time': {
            'type': 'string',
            'description': 'Alarm time (HH:MM or ISO8601)',
          },
          'label': {'type': 'string', 'description': 'Alarm label'},
        },
        required: ['time'],
        implemented: true,
      ),
    );

    add(
      ToolDefinition(
        name: 'generate_on_site',
        description:
            'Generate an image on Artistly inside the in-app browser, '
            'using the user\'s own signed-in session. Only use when the '
            'user asked for an image to be generated. This build only '
            'generates images on Artistly ("site": "artistly", "kind": '
            '"image"); VideoExpress video is not built yet, and any other '
            'site is refused. The user must already be signed in to '
            'Artistly in the browser — never ask for, type, or read a '
            'password.',
        parameters: {
          'site': {
            'type': 'string',
            'description': '"artistly" (only site built in this build)',
          },
          'kind': {
            'type': 'string',
            'description': '"image" (only kind built in this build)',
          },
          'prompt': {
            'type': 'string',
            'description': 'What to generate, in the user\'s words',
          },
          'options': {
            'type': 'object',
            'description': 'Optional style/size settings (may be ignored)',
          },
        },
        required: ['site', 'kind', 'prompt'],
        implemented: true,
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
  /// the model which packages are valid. The cloud path gets the same
  /// tools via [cloudToolsSection] — everything here except
  /// `analyze_image` (build #116 opened `generate_on_site` to cloud
  /// turns) — and parses one tool round there.
  ///
  /// Build #114: [blockedTools] hides tools the user set to Block in
  /// Settings → Tools from the model. The registry has no permission
  /// store of its own, so the caller (the chat screen, which owns the
  /// store) passes the blocked names in.
  Future<String> promptSection({Set<String> blockedTools = const {}}) async {
    final tools = toolsForModel
        .where((t) => !blockedTools.contains(t.name))
        .toList();
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
    lines.addAll(await _connectedAppsLines());
    lines.add(_fileSaveRule);
    lines.add(
      'If no tool fits the request, answer directly in plain text — do not output a tool block.',
    );
    return lines.join('\n');
  }

  /// The enabled connected apps, as prompt lines with their exact package
  /// names — shared by the local section and the cloud section so the
  /// two cannot drift. Empty when nothing is connected: no app list is
  /// not a reason to hide the tools, because the gate still refuses
  /// unconnected packages at execution time.
  Future<List<String>> _connectedAppsLines() async {
    try {
      final enabled = (await ConnectedAppsStore.instance.entries())
          .where((a) => a.enabled)
          .toList();
      if (enabled.isEmpty) return const [];
      return [
        'Connected apps you may open or share to — use the package name exactly:',
        for (final a in enabled) '- ${a.label} (${a.packageName})',
      ];
    } catch (_) {
      // No app list is not a reason to hide the tools: the gate still
      // refuses unconnected packages at execution time.
      return const [];
    }
  }

  /// The file tools a cloud turn may run — and nothing else.
  ///
  /// Build #107: a cloud turn may read and write inside the Projects
  /// folder. Build #115 keeps that pair separate from [cloudTools]
  /// because the file tools carry no permission: they run on a cloud
  /// turn with no Ask dialog, exactly as they have since #107.
  static const Set<String> cloudFileTools = {
    'read_project_file',
    'write_project_file',
  };

  /// Whether [toolName] may run on a cloud turn: file tools only.
  static bool isCloudFileTool(String toolName) =>
      cloudFileTools.contains(toolName);

  /// Every tool a cloud turn may run.
  ///
  /// Build #115: the cloud model runs remotely (HP Ollama / Gemini), so
  /// #107 kept phone-side tools local-only as a trust boundary. That
  /// boundary turned out to be an allowlist, not a technical wall — the
  /// tools execute on the phone in Dart/native either way, and the cloud
  /// model only sends the JSON instruction, exactly as the file tools
  /// already do. Local turns are broken (90s hang, separate fix), so
  /// cloud is the only working path, and a cloud turn that could save
  /// code but not open YouTube was the gap Aaron hit. The set is every
  /// implemented tool except the one that cannot work from a cloud turn:
  ///
  /// - `analyze_image` needs a loaded local vision model; on a cloud
  ///   turn none is loaded, so it could never succeed.
  ///
  /// Build #116: `generate_on_site` joined the set. It drives the
  /// in-app browser through the live WebViewController, and that
  /// controller is reachable from a cloud turn: BrowserScreen is created
  /// once in main_screen.dart and stays mounted through every tab
  /// switch, so it stays registered with BrowserDriver for the whole
  /// app session. It is NOT a silent tool — its default is Ask, so a
  /// cloud generation still asks first, exactly as on the local path
  /// (#114).
  ///
  /// The per-tool permission store still gates every non-file tool here
  /// (see [decideCloudCall]): Block refuses, Ask shows the confirmation
  /// dialog, Allow runs.
  static const Set<String> cloudTools = {
    // File tools (build #107).
    'read_project_file',
    'write_project_file',
    // Phone tools (build #115).
    'open_app',
    'share_to_app',
    'send_sms',
    'create_calendar_event',
    'add_contact',
    'set_alarm',
    'web_search',
    'get_location',
    'create_note',
    'read_notes',
    'create_task',
    'list_tasks',
    'update_task',
    'complete_task',
    'delete_task',
    'create_goal',
    'list_goals',
    'update_goal',
    'complete_goal',
    'delete_goal',
    // Browser generation (build #116): Artistly images on a cloud turn,
    // Ask first — never silent, never a file tool.
    'generate_on_site',
  };

  /// Whether [toolName] may run on a cloud turn.
  static bool isCloudTool(String toolName) => cloudTools.contains(toolName);

  /// What the cloud follow-up does with one tool call from a cloud
  /// reply, given the tool's stored permission.
  ///
  /// Build #115: the decision is a pure function so the table is
  /// unit-testable — the screen itself has no widget test, and a gate
  /// that can only be verified on the phone is a gate that will regress
  /// silently. File tools have no permission: they run, as since #107.
  /// A tool outside [cloudTools] is never executed; the reply is left
  /// as a plain answer.
  static CloudToolDecision decideCloudCall(
    String toolName,
    ToolPermission permission,
  ) {
    if (!isCloudTool(toolName)) return CloudToolDecision.notAllowed;
    if (isCloudFileTool(toolName)) return CloudToolDecision.run;
    if (permission == ToolPermission.block) {
      return CloudToolDecision.refuseBlocked;
    }
    if (permission == ToolPermission.ask) return CloudToolDecision.ask;
    return CloudToolDecision.run;
  }

  /// The tools section for the cloud system prompt, or '' when there is
  /// nothing to offer.
  ///
  /// Build #115: the cloud model gets the phone tools in [cloudTools]
  /// plus the #100 save rule — and the enabled connected apps with
  /// their exact package names, so it never has to guess one. The old
  /// file-only section is gone: a cloud turn that could save code but
  /// not open YouTube was the bug. [blockedTools] hides tools the user
  /// set to Block, same as the local section.
  Future<String> cloudToolsSection({
    Set<String> blockedTools = const {},
  }) async {
    final tools = toolsForModel
        .where(
          (t) => cloudTools.contains(t.name) && !blockedTools.contains(t.name),
        )
        .toList();
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
    lines.addAll(await _connectedAppsLines());
    lines.add(_fileSaveRule);
    lines.add(
      'If no tool fits the request, answer directly in plain text — do not output a tool block.',
    );
    return lines.join('\n');
  }

  /// Build #100: code Cypher writes must land in the Projects folder, or
  /// there is no file to pick it back up from. The rule lives with the
  /// tools sections, because it is about a tool — shared by the local
  /// section and the cloud file-tools section so the two cannot drift.
  static const String _fileSaveRule =
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
      'do not write a file on turns with no code.';

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
      case 'generate_on_site':
        return _executeGenerateOnSite(params);
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
      case 'send_sms':
        return _executeSendSms(params);
      case 'create_calendar_event':
        return _executeCreateCalendarEvent(params);
      case 'add_contact':
        return _executeAddContact(params);
      case 'set_alarm':
        return _executeSetAlarm(params);
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

  /// Records one tool call in the activity log — what ran, with what
  /// parameters, what came back, and under which permission level.
  ///
  /// Build #114: the live chat path never logged tool calls, so a
  /// generation Cypher ran in Aaron's Artistly account left no trace.
  /// The orchestrator has its own private logger for its path; this is
  /// the shared one for callers that run tools directly (the chat
  /// screen). Logging must never break the user's request, so a failure
  /// here is swallowed after one warning.
  static Future<void> logToolCall({
    required String toolName,
    required Map<String, dynamic> params,
    required ToolResult result,
    required String permissionLevel,
  }) async {
    try {
      await DatabaseHelper.instance.insertActivityLog(
        id: const Uuid().v4(),
        toolName: toolName,
        params: jsonEncode(params),
        result: result.toJson(),
        status: result.status.wire,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        permissionLevel: permissionLevel,
      );
    } catch (e) {
      Log.w('ToolRegistry: could not record activity for "$toolName": $e');
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

  /// Why the Projects folder cannot be used right now, or null when it
  /// looks fine.
  ///
  /// Pure so the branches are unit-testable: the callers supply what they
  /// observed — whether the folder path is set, whether it exists on
  /// disk, whether All-files access is granted — and this only picks the
  /// message. Build #107: without All-files access a shared-storage
  /// folder still "exists" but cannot be listed or written, so the model
  /// must be told the grant is missing — not that no folder is picked, or
  /// Aaron gets asked to pick the folder again when it is already set. A
  /// folder that is genuinely gone (access granted, still not there) is
  /// the only case that asks for another pick.
  static String? projectsFolderProblem({
    required String? root,
    required bool folderExists,
    required bool accessGranted,
  }) {
    if (root == null || root.trim().isEmpty) {
      return 'No Projects folder is picked yet. Ask the user to pick one in '
          'Settings → Projects folder first.';
    }
    if (!accessGranted) {
      return 'The Projects folder is set to $root, but Clawzilla cannot '
          'open it — All files access is off. Ask the user to grant it '
          'from Projects → Allow file access. Do not ask them to pick the '
          'folder again — it is already set.';
    }
    if (!folderExists) {
      return 'That folder no longer exists — ask the user to pick another '
          'one in Settings → Projects folder.';
    }
    return null;
  }

  /// The Projects folder problem, if any, as the tool result the model
  /// should see — or null when the folder looks usable.
  ///
  /// No access is a permission the user can grant, not a failure of the
  /// tool, so it reports [ToolStatus.requiresPermission] rather than a
  /// generic failure the model would relay as "pick a folder".
  Future<ToolResult?> _projectsFolderProblem(String root) async {
    var folderExists = false;
    try {
      folderExists = await Directory(root).exists();
    } catch (_) {
      folderExists = false;
    }
    var accessGranted = true;
    try {
      accessGranted =
          await Permission.manageExternalStorage.status.isGranted;
    } catch (_) {
      // The check itself cannot run: fail open and let the IO speak.
      accessGranted = true;
    }
    final message = projectsFolderProblem(
      root: root,
      folderExists: folderExists,
      accessGranted: accessGranted,
    );
    if (message == null) return null;
    if (!accessGranted) return ToolResult.requiresPermission(message);
    return ToolResult.failed(message);
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
    final problem = await _projectsFolderProblem(root);
    if (problem != null) return problem;
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
      // A read that fails after the folder looked usable is usually the
      // folder going away under us — say which, instead of a bare IO
      // error the model would relay as "pick a folder".
      final folderProblem = await _projectsFolderProblem(root);
      if (folderProblem != null) return folderProblem;
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
    final problem = await _projectsFolderProblem(root);
    if (problem != null) return problem;
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
      // Same as the read path: a write that fails after the folder
      // looked usable is usually access going away, not a missing folder.
      final folderProblem = await _projectsFolderProblem(root);
      if (folderProblem != null) return folderProblem;
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

  /// Asks Android for [permission] (system runtime dialog on first use)
  /// and reports the outcome. Mirrors the location service
  /// (`Permission.location.request().isGranted`). A channel failure is a
  /// denial, not a grant: failing closed is the only safe direction.
  Future<PermissionStatus> _ensurePermission(Permission permission) async {
    try {
      final current = await permission.status;
      if (current.isGranted) return current;
      return await permission.request();
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  /// The denial message for a silent tool: what to grant, and where. A
  /// permanent denial means the system dialog will not show again, so
  /// that one names Settings explicitly.
  ToolResult _permissionDenied(String what, PermissionStatus status) {
    if (status.isPermanentlyDenied) {
      return ToolResult.requiresPermission(
        '$what permission is denied — allow it in Settings → Apps → '
        'Clawzilla → Permissions, then ask again.',
      );
    }
    return ToolResult.requiresPermission(
      '$what permission was not granted, so nothing was done.',
    );
  }

  /// Whether [recipient] is a bare phone number, mirroring the native
  /// `resolveSmsNumber` check exactly: digits and phone punctuation only,
  /// with at least 7 digits. Anything else is a contact name and needs
  /// the contacts permission to resolve.
  static bool _isSmsNumber(String recipient) {
    final digits = recipient.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) return false;
    return RegExp(r'^[0-9+\- ().]+$').hasMatch(recipient);
  }

  /// Sends an SMS with SmsManager — no composer, no confirmation. The
  /// recipient may be a phone number or a contact name (the native side
  /// looks the name up). Returns success only when SmsManager accepted
  /// the message; a wrong-but-valid recipient goes out as-is, which is
  /// the silent behaviour Aaron asked for (build #110).
  ///
  /// Build #117: a name recipient is looked up in the contacts provider,
  /// which needs READ_CONTACTS — so the contacts permission is requested
  /// first when the recipient is not a bare number. Before #117 only
  /// Permission.sms was requested here, so texting "Shannon" always
  /// failed with no_number even though she was in his contacts: the
  /// native lookup threw SecurityException and returned null before
  /// anything was sent.
  Future<ToolResult> _executeSendSms(Map<String, dynamic> params) async {
    final recipient = (params['recipient'] as String?)?.trim();
    final message = (params['message'] as String?)?.trim();
    if (recipient == null || recipient.isEmpty) {
      return ToolResult.failed('send_sms requires a "recipient".');
    }
    if (message == null || message.isEmpty) {
      return ToolResult.failed('send_sms requires a "message".');
    }
    // The native side looks a name up to a number first, and that lookup
    // needs READ_CONTACTS — ask for it before the SMS permission, in the
    // same order the native call uses them. A bare number needs no
    // contacts access, so it must not pop a contacts dialog.
    if (!_isSmsNumber(recipient)) {
      final contacts = await _ensurePermission(Permission.contacts);
      if (!contacts.isGranted) {
        return _permissionDenied('Contacts', contacts);
      }
    }
    final permission = await _ensurePermission(Permission.sms);
    if (!permission.isGranted) {
      return _permissionDenied('SMS', permission);
    }
    try {
      final result = await _appsChannel.invokeMethod<String>(
        'sendSms',
        {'recipient': recipient, 'message': message},
      );
      return switch (result) {
        'ok' => ToolResult.success('Sent the SMS to $recipient.'),
        'no_number' => ToolResult.failed(
          'No phone number found for "$recipient" — check the name or '
          'number.',
        ),
        _ => ToolResult.failed('Could not send the SMS.'),
      };
    } on PlatformException catch (e) {
      return ToolResult.failed('Could not send the SMS: ${e.message}');
    }
  }

  /// Creates a calendar event with ContentResolver — no calendar app,
  /// no confirmation. The native side picks the primary calendar (or
  /// the first visible one). End defaults to one hour after start.
  Future<ToolResult> _executeCreateCalendarEvent(
    Map<String, dynamic> params,
  ) async {
    final title = (params['title'] as String?)?.trim();
    final startRaw = (params['start_time'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return ToolResult.failed('create_calendar_event requires a "title".');
    }
    final start = startRaw == null ? null : DateTime.tryParse(startRaw);
    if (start == null) {
      return ToolResult.failed(
        'create_calendar_event requires a readable "start_time" '
        '(ISO8601, e.g. 2026-11-17T14:00:00).',
      );
    }
    final endRaw = (params['end_time'] as String?)?.trim();
    final end = (endRaw == null || endRaw.isEmpty)
        ? start.add(const Duration(hours: 1))
        : DateTime.tryParse(endRaw);
    if (end == null) {
      return ToolResult.failed(
        'create_calendar_event could not read "end_time" '
        '(ISO8601, e.g. 2026-11-17T15:00:00).',
      );
    }
    final location = (params['location'] as String?)?.trim();
    final permission = await _ensurePermission(
      Permission.calendarFullAccess,
    );
    if (!permission.isGranted) {
      return _permissionDenied('Calendar', permission);
    }
    try {
      final created = await _appsChannel.invokeMethod<bool>(
        'insertCalendarEvent',
        {
          'title': title,
          'beginMillis': start.millisecondsSinceEpoch,
          'endMillis': end.millisecondsSinceEpoch,
          if (location != null && location.isNotEmpty) 'location': location,
        },
      );
      if (created != true) {
        return ToolResult.failed(
          'Could not create the calendar event — no calendar on this '
          'phone accepted it.',
        );
      }
      return ToolResult.success('Created the calendar event "$title".');
    } on PlatformException catch (e) {
      return ToolResult.failed(
        'Could not create the calendar event: ${e.message}',
      );
    }
  }

  /// Adds a contact with ContentResolver — no contacts app, no
  /// confirmation. The contact is stored locally (no account).
  Future<ToolResult> _executeAddContact(Map<String, dynamic> params) async {
    final name = (params['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      return ToolResult.failed('add_contact requires a "name".');
    }
    final phone = (params['phone'] as String?)?.trim();
    final email = (params['email'] as String?)?.trim();
    final permission = await _ensurePermission(Permission.contacts);
    if (!permission.isGranted) {
      return _permissionDenied('Contacts', permission);
    }
    try {
      final added = await _appsChannel.invokeMethod<bool>(
        'insertContact',
        {
          'name': name,
          if (phone != null && phone.isNotEmpty) 'phone': phone,
          if (email != null && email.isNotEmpty) 'email': email,
        },
      );
      if (added != true) {
        return ToolResult.failed('Could not add the contact.');
      }
      return ToolResult.success('Added "$name" to contacts.');
    } on PlatformException catch (e) {
      return ToolResult.failed('Could not add the contact: ${e.message}');
    }
  }

  /// Sets an alarm with AlarmManager (setAlarmClock) — no clock app, no
  /// confirmation. The alarm rings on this phone: the native receiver
  /// plays the alarm tone on loop with a notification to dismiss it.
  /// Hour/minute/label only — the alarm takes no absolute date, so a
  /// time already past today rings tomorrow.
  Future<ToolResult> _executeSetAlarm(Map<String, dynamic> params) async {
    final timeRaw = (params['time'] as String?)?.trim();
    final when = timeRaw == null ? null : _parseAlarmTime(timeRaw);
    if (when == null) {
      return ToolResult.failed(
        'set_alarm requires a readable "time" (ISO8601, e.g. '
        '2026-11-17T06:00:00, or "06:00").',
      );
    }
    final label = (params['label'] as String?)?.trim();
    try {
      final result = await _appsChannel.invokeMethod<String>(
        'setAlarm',
        {
          'hour': when.hour,
          'minute': when.minute,
          if (label != null && label.isNotEmpty) 'label': label,
        },
      );
      return switch (result) {
        'ok' => ToolResult.success(
          'Set the alarm for ${_twoDigits(when.hour)}:'
          '${_twoDigits(when.minute)}.',
        ),
        'exact_alarm_denied' => ToolResult.requiresPermission(
          'Alarms & reminders is off for Clawzilla — I opened Settings '
          'so you can turn it on, then ask again.',
        ),
        _ => ToolResult.failed('Could not set the alarm.'),
      };
    } on PlatformException catch (e) {
      return ToolResult.failed('Could not set the alarm: ${e.message}');
    }
  }

  /// Reads an alarm time: a full ISO8601 timestamp first, or a bare
  /// "HH:MM" (the model often gives just the time — take today at that
  /// hour; the native side rolls it to tomorrow if it already passed).
  DateTime? _parseAlarmTime(String raw) {
    final full = DateTime.tryParse(raw.trim());
    if (full != null) return full;
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
    if (m == null) return null;
    final hour = int.tryParse(m.group(1)!);
    final minute = int.tryParse(m.group(2)!);
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return null;
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute);
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

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

  /// Generates media on a website through the in-app browser.
  ///
  /// Build #114: one self-contained call — the chat path runs exactly
  /// one tool round per turn, so the whole generation (navigate, fill,
  /// click, wait for the result) has to happen inside this call.
  ///
  /// Guardrails, in order: the site allowlist is enforced here before
  /// anything loads; only Artistly images are built in this build
  /// (VideoExpress video is refused as unimplemented, not attempted);
  /// the driver acts inside Aaron's already-signed-in session and never
  /// sees, stores, types, or reads credentials. Build #116: this tool
  /// runs on cloud turns too, through the same Ask gate as the other
  /// phone tools — the driver call is guarded so a mid-run failure
  /// returns a failed result instead of throwing out of executeTool
  /// and killing the turn.
  Future<ToolResult> _executeGenerateOnSite(
    Map<String, dynamic> params,
  ) async {
    final site = (params['site'] as String?)?.trim().toLowerCase();
    final kind = (params['kind'] as String?)?.trim().toLowerCase();
    final prompt = (params['prompt'] as String?)?.trim();

    if (site == null || site.isEmpty) {
      return ToolResult.failed(
        'generate_on_site requires a "site".',
      );
    }
    if (!BrowserDriver.allowedSites.contains(site)) {
      return ToolResult.failed(
        'Cypher can only generate on Artistly and VideoExpress — '
        '"$site" is refused. Nothing was opened.',
      );
    }
    if (kind == null || kind.isEmpty) {
      return ToolResult.failed('generate_on_site requires a "kind".');
    }
    if (site == 'videoexpress') {
      // The allowlist names both sites, but only the Artistly image
      // recipe is built in this build. Refused as unimplemented — the
      // model is told plainly, and nothing is opened. This runs before
      // the kind check so a video request to VideoExpress reports "not
      // built yet" instead of "bad kind".
      return ToolResult.unsupported(
        'Generating on VideoExpress is not built yet — Artistly images '
        'only in this build. Nothing was opened.',
      );
    }
    if (kind != 'image') {
      return ToolResult.failed(
        'Only "image" generation is built in this build — "$kind" is '
        'not supported yet.',
      );
    }
    if (prompt == null || prompt.isEmpty) {
      return ToolResult.failed(
        'generate_on_site requires a non-empty "prompt".',
      );
    }

    BrowserGenerationResult result;
    try {
      result = await BrowserDriver.instance.generateOnArtistly(
        prompt: prompt,
      );
    } catch (e) {
      // A mid-run failure (the controller unregistered under us, a JS
      // evaluation throwing) must fail the tool honestly, not throw out
      // of executeTool and kill the whole turn with a snackbar.
      return ToolResult.failed('Artistly generation failed: $e');
    }
    switch (result.status) {
      case BrowserGenerationStatus.ready:
        return ToolResult.success(
          result.message,
          data: {
            'site': site,
            'kind': kind,
            'prompt': prompt,
            'status': 'ready',
            'urls': result.urls,
          },
        );
      case BrowserGenerationStatus.generating:
        // The generation started — the click landed — but no result
        // appeared within the poll cap. Success is honest here: the
        // action (starting the generation) happened; the result is
        // pending, and the message says exactly that.
        return ToolResult.success(
          result.message,
          data: {
            'site': site,
            'kind': kind,
            'prompt': prompt,
            'status': 'generating',
          },
        );
      case BrowserGenerationStatus.failed:
        return ToolResult.failed(result.message);
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
