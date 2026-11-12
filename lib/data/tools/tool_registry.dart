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
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/json_extract.dart';
import '../../domain/models/tool_result.dart';
import '../services/connected_apps_store.dart';
import '../services/llm_service.dart';
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
        description: 'Get the device current location.',
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
      default:
        return ToolResult.unsupported('No implementation for "$toolName".');
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
      );
      return ToolResult.success(
        'Location acquired.',
        data: {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': position.timestamp.toIso8601String(),
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
