/// Tests for the tool layer.
///
/// These exist because of a specific failure: seven tools returned
/// `{"status":"success"}` without doing anything, so the model told the user
/// their SMS had been sent when no message existed. Every test below is an
/// attempt to make that impossible to reintroduce.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/core/utils/json_extract.dart';
import 'package:clawzilla/data/tools/tool_permission_store.dart';
import 'package:clawzilla/data/tools/tool_registry.dart';
import 'package:clawzilla/domain/models/tool_result.dart';

void main() {
  final registry = ToolRegistry()..registerTools();

  group('ToolDefinition.schema', () {
    test('every registered tool produces parseable JSON', () {
      expect(registry.tools, isNotEmpty);
      for (final def in registry.tools.values) {
        // The old implementation built this string by interpolation, so any
        // description containing a quote produced invalid JSON. Decoding is
        // the only way to know it is well formed.
        final decoded = jsonDecode(def.schema);
        expect(
          decoded,
          isA<Map<String, dynamic>>(),
          reason: '${def.name} schema did not decode to an object',
        );
      }
    });

    test('schema carries the expected shape', () {
      for (final def in registry.tools.values) {
        final decoded = jsonDecode(def.schema) as Map<String, dynamic>;
        expect(decoded['name'], def.name);
        expect(decoded['description'], isA<String>());

        final params = decoded['parameters'] as Map<String, dynamic>;
        expect(params['type'], 'object');
        expect(params['properties'], isA<Map<String, dynamic>>());
        expect(params['required'], isA<List<dynamic>>());
      }
    });

    test('required matches the declared list and never throws', () {
      final sms = registry.tools['send_sms']!;
      final decoded = jsonDecode(sms.schema) as Map<String, dynamic>;
      final params = decoded['parameters'] as Map<String, dynamic>;
      final required = (params['required'] as List).cast<String>();

      expect(required, containsAll(<String>['recipient', 'message']));
    });

    test('a description containing quotes still yields valid JSON', () {
      // Regression: the previous builder interpolated description text
      // directly, so a quote broke the whole payload.
      final def = ToolDefinition(
        name: 'quote_test',
        description: 'Says "hello" and \\ backslash',
        parameters: {
          'q': {'type': 'string', 'description': 'has a "quote" inside'},
        },
        required: const ['q'],
        implemented: false,
      );

      final decoded = jsonDecode(def.schema) as Map<String, dynamic>;
      expect(decoded['description'], 'Says "hello" and \\ backslash');
      final props =
          (decoded['parameters'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      expect(props['q']['description'], 'has a "quote" inside');
    });

    test('the never-set "optional" key is gone', () {
      // The old code derived `required` from `!parameters[k]['optional']`, and
      // no tool ever set `optional`, so this was a null-check on null and threw.
      for (final def in registry.tools.values) {
        for (final entry in def.parameters.entries) {
          expect(
            (entry.value as Map).containsKey('optional'),
            isFalse,
            reason: '${def.name}.${entry.key} still carries "optional"',
          );
        }
      }
    });
  });

  group('ToolRegistry', () {
    test('registerTools populates the registry', () {
      // It was never called before, so the registry was permanently empty.
      expect(registry.tools.length, greaterThan(5));
    });

    test('unimplemented tools are hidden from the model', () {
      final offered = registry.toolsForModel.map((t) => t.name).toSet();

      // These have real implementations and must be offered.
      expect(offered, contains('analyze_image'));
      expect(offered, contains('web_search'));

      // Connected apps left the v1 gate (Nov 7, 2026): open_app is
      // implemented through the native channel and gated per-app at
      // execution time, and share_to_app is its share/send half.
      expect(offered, contains('open_app'));
      expect(offered, contains('share_to_app'));

      // Live location left the v1 gate (Nov 11, 2026): Aaron approved it
      // so the model can know where he is and the temperature.
      expect(offered, contains('get_location'));

      // Project files left the gate (Nov 12, 2026, build #86): Aaron
      // said Cypher can edit code too, so the model may read and write
      // inside the Projects folder — and nowhere else.
      expect(offered, contains('read_project_file'));
      expect(offered, contains('write_project_file'));

      // Tasks and Goals left manual-only (Nov 14, 2026, build #95):
      // Aaron said the tabs are for the agent to do, not him, so the
      // model may manage tasks and goals in the same tables the tabs
      // read. These are plain database writes, no Android permission.
      for (final tool in [
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
      ]) {
        expect(offered, contains(tool));
      }

      // These do nothing yet, so the model must not see them.
      expect(offered, isNot(contains('send_sms')));
      expect(offered, isNot(contains('add_contact')));

      // v1 gate: implemented tools blocked for v1 are also not offered.
      final expectedOffered = registry.tools.values
          .where((t) =>
              t.implemented && !ToolPermissionStore.isV1Gated(t.name))
          .length;
      expect(offered.length, expectedOffered);
    });

    test('no unimplemented tool can ever report success', () async {
      final unimplemented = registry.tools.values
          .where((t) => !t.implemented)
          .toList();
      expect(unimplemented, isNotEmpty);

      for (final def in unimplemented) {
        final result = await registry.executeTool(
          toolName: def.name,
          params: const {},
        );
        expect(
          result.status,
          ToolStatus.unsupported,
          reason: '${def.name} must not claim success',
        );
        expect(result.isSuccess, isFalse);
        expect(
          result.message,
          isNotEmpty,
          reason: '${def.name} must explain why it cannot run',
        );
      }
    });

    test('an unconnected app is refused, never opened or shared to', () async {
      // The per-app gate: a package Aaron never connected must be refused
      // at execution time, before Android is ever asked. The store is
      // empty in a unit test, so nothing is connected here — and the gate
      // must fail closed rather than throw on the unreadable store.
      for (final tool in ['open_app', 'share_to_app']) {
        final result = await registry.executeTool(
          toolName: tool,
          params: {
            'package_name': 'com.example.notconnected',
            'text': 'hello',
          },
        );
        expect(
          result.status,
          ToolStatus.unsupported,
          reason: '$tool must refuse an unconnected package',
        );
        expect(result.isSuccess, isFalse);
      }
    });

    test('an unknown tool fails rather than silently succeeding', () async {
      final result = await registry.executeTool(
        toolName: 'does_not_exist',
        params: const {},
      );
      expect(result.status, ToolStatus.failed);
      expect(result.isSuccess, isFalse);
    });

    test('isImplemented agrees with the registry', () {
      expect(registry.isImplemented('get_location'), isTrue);
      expect(registry.isImplemented('open_app'), isTrue);
      expect(registry.isImplemented('share_to_app'), isTrue);
      expect(registry.isImplemented('create_task'), isTrue);
      expect(registry.isImplemented('list_goals'), isTrue);
      expect(registry.isImplemented('send_sms'), isFalse);
      expect(registry.isImplemented('nope'), isFalse);
    });

    test('task and goal tools refuse bad input before touching the database',
        () async {
      // These fail in validation, before any DatabaseHelper call — so
      // they are safe to run in a unit test, where sqflite has no
      // platform channel. A success here would mean a tool claimed to
      // act while doing nothing, the exact failure this file guards.
      for (final tool in [
        'create_task',
        'create_goal',
        'update_task',
        'update_goal',
        'complete_task',
        'complete_goal',
        'delete_task',
        'delete_goal',
      ]) {
        final result = await registry.executeTool(
          toolName: tool,
          params: const {},
        );
        expect(
          result.status,
          ToolStatus.failed,
          reason: '$tool with no params must fail, not succeed',
        );
        expect(result.isSuccess, isFalse);
      }
    });
  });

  group('parseToolCall', () {
    test('parses a fenced json block', () {
      final call = parseToolCall(
        '```json\n{"tool": "open_app", "params": {"package_name": "com.google.android.youtube"}}\n```',
      );
      expect(call, isNotNull);
      expect(call!.tool, 'open_app');
      expect(call.params['package_name'], 'com.google.android.youtube');
    });

    test('parses a bare object and defaults missing params', () {
      final call = parseToolCall('{"tool": "web_search"}');
      expect(call, isNotNull);
      expect(call!.tool, 'web_search');
      expect(call.params, isEmpty);
    });

    test('returns null when there is no tool call', () {
      expect(parseToolCall('Just answer this.'), isNull);
      expect(parseToolCall('{"answer": 42}'), isNull);
      expect(parseToolCall('```json\n{ broken\n```'), isNull);
      expect(parseToolCall(''), isNull);
    });
  });

  group('ToolRegistry.promptSection', () {
    test('lists offered tools, never gated ones', () async {
      final section = await registry.promptSection();
      expect(section, contains('open_app'));
      expect(section, contains('web_search'));
      expect(section, contains('get_location'));
      expect(section, contains('create_task'));
      expect(section, contains('list_tasks'));
      expect(section, contains('create_goal'));
      expect(section, isNot(contains('send_sms')));
      expect(section, isNot(contains('add_contact')));
    });

    test('tells the model to save code it writes', () async {
      // Build #100: code Cypher writes must land in the Projects folder,
      // or there is no file to pick it back up from.
      final section = await registry.promptSection();

      expect(section, contains('write_project_file'));
      expect(section, contains('save it with write_project_file'));
      expect(section, contains('Projects folder'));
      expect(section, contains('distinct name'));
      expect(section, contains('Only save code the turn actually produced'));
    });
  });

  group('ToolRegistry.distinctPath', () {
    test('returns the candidate when it is free', () {
      expect(
        ToolRegistry.distinctPath('/p/main.dart', (_) => false),
        '/p/main.dart',
      );
    });

    test('suffixed names before the extension, counting up', () {
      final taken = {'/p/main.dart', '/p/main-2.dart'};
      expect(
        ToolRegistry.distinctPath('/p/main.dart', taken.contains),
        '/p/main-3.dart',
      );
    });

    test('appends the suffix when there is no extension', () {
      final taken = {'/p/README'};
      expect(
        ToolRegistry.distinctPath('/p/README', taken.contains),
        '/p/README-2',
      );
    });

    test('returns null when no distinct name is free', () {
      expect(ToolRegistry.distinctPath('/p/x.dart', (_) => true), isNull);
    });
  });

  group('ToolResult', () {
    test('wire statuses are stable', () {
      expect(ToolResult.success('x').status.wire, 'success');
      expect(ToolResult.failed('x').status.wire, 'failed');
      expect(ToolResult.unsupported('x').status.wire, 'unsupported');
      expect(
        ToolResult.requiresPermission('x').status.wire,
        'requires_permission',
      );
      expect(
        ToolResult.awaitingConfirmation('x').status.wire,
        'awaiting_confirmation',
      );
      expect(
        ToolResult.requiresUserAction('x').status.wire,
        'requires_user_action',
      );
    });

    test('only success counts as a completed action', () {
      expect(ToolResult.success('ok').isCompletedAction, isTrue);

      // Opening the SMS composer is not the same as sending a message.
      expect(
        ToolResult.requiresUserAction('composer opened').isCompletedAction,
        isFalse,
      );
      expect(ToolResult.unsupported('nope').isCompletedAction, isFalse);
      expect(ToolResult.failed('boom').isCompletedAction, isFalse);
      expect(
        ToolResult.requiresPermission('need it').isCompletedAction,
        isFalse,
      );
      expect(
        ToolResult.awaitingConfirmation('ask me').isCompletedAction,
        isFalse,
      );
    });

    test('never reports success for a non-success status', () {
      final notSuccess = <ToolResult>[
        ToolResult.failed('a'),
        ToolResult.unsupported('b'),
        ToolResult.requiresPermission('c'),
        ToolResult.awaitingConfirmation('d'),
        ToolResult.requiresUserAction('e'),
      ];
      for (final r in notSuccess) {
        expect(r.isSuccess, isFalse);
      }
    });

    test('serialises to JSON the model can read', () {
      final decoded = jsonDecode(
        ToolResult.success('done', data: {'answer': 42}).toJson(),
      ) as Map<String, dynamic>;
      expect(decoded['status'], 'success');
      expect(decoded['message'], 'done');
      expect(decoded['answer'], 42);
    });
  });

  group('extractJsonObject', () {
    test('parses a bare object', () {
      final r = extractJsonObject('{"plan": []}');
      expect(r, isNotNull);
      expect(r!['plan'], isEmpty);
    });

    test('unwraps a fenced block', () {
      final r = extractJsonObject('```json\n{"plan": [1]}\n```');
      expect(r, isNotNull);
      expect(r!['plan'], [1]);
    });

    test('unwraps a fence with leading prose', () {
      final r = extractJsonObject(
        'Sure! Here is the plan:\n```json\n{"plan": ["a"]}\n```\nHope that helps.',
      );
      expect(r, isNotNull);
      expect(r!['plan'], ['a']);
    });

    test('finds an object inside surrounding prose', () {
      final r = extractJsonObject('The answer is {"plan": []} as requested');
      expect(r, isNotNull);
      expect(r!['plan'], isEmpty);
    });

    test('returns null for unparseable input rather than throwing', () {
      // Returning null is what lets the orchestrator fall back to answering the
      // question directly. Throwing here is what used to strand the agent.
      expect(extractJsonObject(''), isNull);
      expect(extractJsonObject('I cannot help with that.'), isNull);
      expect(extractJsonObject('{ not json at all '), isNull);
      expect(extractJsonObject('```json\n{ broken\n```'), isNull);
    });

    test('ignores a JSON array at the top level', () {
      expect(extractJsonObject('[1,2,3]'), isNull);
    });
  });

  group('ToolRegistry.fileToolsSection (build #107)', () {
    test('offers only the file tools, with the save rule', () async {
      final section = await registry.fileToolsSection();
      expect(section, contains('read_project_file'));
      expect(section, contains('write_project_file'));
      expect(section, contains('save it with write_project_file'));
      expect(section, contains('Only save code the turn actually produced'));
    });

    test('never offers a phone-side tool to a cloud turn', () async {
      final section = await registry.fileToolsSection();
      for (final tool in [
        'open_app',
        'share_to_app',
        'web_search',
        'get_location',
        'create_note',
        'read_notes',
        'analyze_image',
        'create_task',
        'list_tasks',
        'create_goal',
        'send_sms',
      ]) {
        expect(
          section,
          isNot(contains(tool)),
          reason: 'cloud turns must never see $tool',
        );
      }
      expect(section, isNot(contains('Connected apps')));
    });
  });

  group('ToolRegistry.isCloudFileTool (build #107)', () {
    test('file tools run on cloud turns, nothing else does', () {
      expect(ToolRegistry.isCloudFileTool('read_project_file'), isTrue);
      expect(ToolRegistry.isCloudFileTool('write_project_file'), isTrue);
      for (final tool in [
        'open_app',
        'share_to_app',
        'web_search',
        'get_location',
        'create_note',
        'create_task',
        'send_sms',
        'does_not_exist',
      ]) {
        expect(
          ToolRegistry.isCloudFileTool(tool),
          isFalse,
          reason: '$tool must never run on a cloud turn',
        );
      }
    });
  });

  group('ToolRegistry.projectsFolderProblem (build #107)', () {
    test('no folder set asks for a pick', () {
      for (final root in [null, '', '   ']) {
        final message = ToolRegistry.projectsFolderProblem(
          root: root,
          folderExists: false,
          accessGranted: true,
        );
        expect(message, isNotNull);
        expect(message, contains('No Projects folder is picked yet'));
      }
    });

    test('folder set but access off blames the grant, never a re-pick',
        () {
      // Without All-files access a shared-storage folder still "exists"
      // but cannot be listed or written. Either way the model must send
      // Aaron to the grant, not back to the picker.
      for (final folderExists in [true, false]) {
        final message = ToolRegistry.projectsFolderProblem(
          root: '/storage/emulated/0/Projects',
          folderExists: folderExists,
          accessGranted: false,
        );
        expect(message, isNotNull);
        expect(message, contains('All files access is off'));
        expect(message, contains('already set'));
        expect(message, isNot(contains('no longer exists')));
        expect(message, isNot(contains('pick another')));
      }
    });

    test('folder genuinely gone asks for another pick', () {
      final message = ToolRegistry.projectsFolderProblem(
        root: '/storage/emulated/0/Projects',
        folderExists: false,
        accessGranted: true,
      );
      expect(message, isNotNull);
      expect(message, contains('no longer exists'));
    });

    test('folder set, present, and accessible is fine', () {
      expect(
        ToolRegistry.projectsFolderProblem(
          root: '/storage/emulated/0/Projects',
          folderExists: true,
          accessGranted: true,
        ),
        isNull,
      );
    });
  });
}
