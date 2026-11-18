/// Tests for the tool layer.
///
/// These exist because of a specific failure: seven tools returned
/// `{"status":"success"}` without doing anything, so the model told the user
/// their SMS had been sent when no message existed. Every test below is an
/// attempt to make that impossible to reintroduce.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/core/utils/json_extract.dart';
import 'package:clawzilla/data/services/browser_driver.dart';
import 'package:clawzilla/data/services/connected_apps_store.dart';
import 'package:clawzilla/data/tools/tool_permission_store.dart';
import 'package:clawzilla/data/tools/tool_registry.dart';
import 'package:clawzilla/domain/models/tool_result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

      // The four silent tools (build #110): implemented, ungated, and
      // offered — the model must see them to use them.
      for (final tool in [
        'send_sms',
        'create_calendar_event',
        'add_contact',
        'set_alarm',
      ]) {
        expect(offered, contains(tool));
      }

      // v1 gate: implemented tools blocked for v1 are also not offered.
      final expectedOffered = registry.tools.values
          .where((t) =>
              t.implemented && !ToolPermissionStore.isV1Gated(t.name))
          .length;
      expect(offered.length, expectedOffered);
    });

    test('no unimplemented tool can ever report success', () async {
      // Every registered tool is now implemented — build #110 finished
      // the last four stubs. The loop below stays as the guard: if a
      // stub is ever added again, it must fail with `unsupported` and
      // never claim success.
      final unimplemented = registry.tools.values
          .where((t) => !t.implemented)
          .toList();
      expect(unimplemented, isEmpty);

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
  });

  group('open_app connected gate (build #115)', () {
    const appsChannel = MethodChannel('clawzilla/apps');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(appsChannel, (call) async {
        if (call.method == 'launchApp') return true;
        if (call.method == 'shareToApp') return true;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(appsChannel, null);
      ConnectedAppsStore.entriesOverride = null;
    });

    test('a connected, enabled app opens', () async {
      // The positive case the #115 cloud turn needs: YouTube connected
      // and switched on must actually launch. The store override stands
      // in for the database, which sqflite cannot open in a unit test.
      ConnectedAppsStore.entriesOverride = [
        const ConnectedAppEntry(
          packageName: 'com.google.android.youtube',
          label: 'YouTube',
          enabled: true,
        ),
      ];
      final result = await registry.executeTool(
        toolName: 'open_app',
        params: {'package_name': 'com.google.android.youtube'},
      );
      expect(result.status, ToolStatus.success);
      expect(result.isSuccess, isTrue);
    });

    test('a connected but disabled app is refused', () async {
      ConnectedAppsStore.entriesOverride = [
        const ConnectedAppEntry(
          packageName: 'com.google.android.youtube',
          label: 'YouTube',
          enabled: false,
        ),
      ];
      final result = await registry.executeTool(
        toolName: 'open_app',
        params: {'package_name': 'com.google.android.youtube'},
      );
      expect(result.status, ToolStatus.unsupported);
      expect(result.isSuccess, isFalse);
    });

    test('a connected, enabled app shares — user confirms in the app',
        () async {
      ConnectedAppsStore.entriesOverride = [
        const ConnectedAppEntry(
          packageName: 'com.google.android.youtube',
          label: 'YouTube',
          enabled: true,
        ),
      ];
      final result = await registry.executeTool(
        toolName: 'share_to_app',
        params: {
          'package_name': 'com.google.android.youtube',
          'text': 'hello',
        },
      );
      expect(result.status, ToolStatus.requiresUserAction);
      expect(result.isSuccess, isFalse);
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
      // The four silent tools are implemented (build #110) — they send
      // directly, no Intent stub left.
      expect(registry.isImplemented('send_sms'), isTrue);
      expect(registry.isImplemented('create_calendar_event'), isTrue);
      expect(registry.isImplemented('add_contact'), isTrue);
      expect(registry.isImplemented('set_alarm'), isTrue);
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
      // The four silent tools are offered now (build #110): the model
      // must see them in the prompt to use them.
      expect(section, contains('send_sms'));
      expect(section, contains('create_calendar_event'));
      expect(section, contains('add_contact'));
      expect(section, contains('set_alarm'));
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

  group('ToolRegistry.cloudToolsSection (build #115)', () {
    test('offers the file tools and the phone tools, with the save rule',
        () async {
      final section = await registry.cloudToolsSection();
      for (final tool in [
        'read_project_file',
        'write_project_file',
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
        'create_goal',
        'list_goals',
      ]) {
        // The '- name:' list line, not a bare substring: the JSON
        // example at the top of the section names open_app too.
        expect(section, contains('- $tool:'), reason: 'cloud turns see $tool');
      }
      expect(section, contains('save it with write_project_file'));
      expect(section, contains('Only save code the turn actually produced'));
    });

    test('never offers generate_on_site or analyze_image to a cloud turn',
        () async {
      // generate_on_site drives the in-app browser through the live
      // controller (local-only, #114); analyze_image needs a loaded
      // local vision model, which a cloud turn never has.
      final section = await registry.cloudToolsSection();
      expect(section, isNot(contains('generate_on_site')));
      expect(section, isNot(contains('analyze_image')));
    });

    test('with no connected apps, no apps list is shown', () async {
      final section = await registry.cloudToolsSection();
      // The list header line specifically: tool descriptions mention
      // "Connected apps" in prose, so a bare substring would false-trip.
      expect(section, isNot(contains('Connected apps you may open')));
    });

    test('a Blocked tool is hidden from the cloud section', () async {
      final section =
          await registry.cloudToolsSection(blockedTools: {'open_app'});
      expect(section, isNot(contains('- open_app:')));
      expect(section, contains('- web_search:'));
    });
  });

  group('ToolRegistry.isCloudTool (build #115)', () {
    test('every cloud tool runs on cloud turns', () {
      for (final tool in ToolRegistry.cloudTools) {
        expect(
          ToolRegistry.isCloudTool(tool),
          isTrue,
          reason: '$tool must run on a cloud turn',
        );
      }
      expect(ToolRegistry.cloudTools.length, 22);
    });

    test('generate_on_site, analyze_image, and unknown names do not', () {
      for (final tool in [
        'generate_on_site',
        'analyze_image',
        'does_not_exist',
      ]) {
        expect(
          ToolRegistry.isCloudTool(tool),
          isFalse,
          reason: '$tool must never run on a cloud turn',
        );
      }
    });
  });

  group('ToolRegistry.isCloudFileTool (build #107, kept by #115)', () {
    test('only the file tools are file tools', () {
      expect(ToolRegistry.isCloudFileTool('read_project_file'), isTrue);
      expect(ToolRegistry.isCloudFileTool('write_project_file'), isTrue);
      for (final tool in [
        'open_app',
        'send_sms',
        'web_search',
        'generate_on_site',
      ]) {
        expect(
          ToolRegistry.isCloudFileTool(tool),
          isFalse,
          reason: '$tool is a cloud tool, not a file tool',
        );
      }
    });
  });

  group('ToolRegistry.decideCloudCall (build #115)', () {
    test('file tools run with no permission question', () {
      for (final permission in ToolPermission.values) {
        expect(
          ToolRegistry.decideCloudCall('write_project_file', permission),
          CloudToolDecision.run,
        );
      }
    });

    test('Allow runs a phone tool', () {
      expect(
        ToolRegistry.decideCloudCall('open_app', ToolPermission.allow),
        CloudToolDecision.run,
      );
      expect(
        ToolRegistry.decideCloudCall('send_sms', ToolPermission.allow),
        CloudToolDecision.run,
      );
    });

    test('Block refuses without running', () {
      expect(
        ToolRegistry.decideCloudCall('open_app', ToolPermission.block),
        CloudToolDecision.refuseBlocked,
      );
      expect(
        ToolRegistry.decideCloudCall('send_sms', ToolPermission.block),
        CloudToolDecision.refuseBlocked,
      );
      expect(
        ToolRegistry.decideCloudCall('delete_task', ToolPermission.block),
        CloudToolDecision.refuseBlocked,
      );
    });

    test('Ask means ask first', () {
      expect(
        ToolRegistry.decideCloudCall('open_app', ToolPermission.ask),
        CloudToolDecision.ask,
      );
      expect(
        ToolRegistry.decideCloudCall('web_search', ToolPermission.ask),
        CloudToolDecision.ask,
      );
    });

    test('tools outside the cloud set are never executed', () {
      for (final permission in ToolPermission.values) {
        expect(
          ToolRegistry.decideCloudCall('generate_on_site', permission),
          CloudToolDecision.notAllowed,
        );
        expect(
          ToolRegistry.decideCloudCall('analyze_image', permission),
          CloudToolDecision.notAllowed,
        );
        expect(
          ToolRegistry.decideCloudCall('does_not_exist', permission),
          CloudToolDecision.notAllowed,
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

  group('silent tools (build #110)', () {
    test('the v1 gate is empty and the four tools default to allow', () {
      expect(ToolPermissionStore.v1GatedTools, isEmpty);
      for (final tool in [
        'send_sms',
        'create_calendar_event',
        'add_contact',
        'set_alarm',
      ]) {
        expect(ToolPermissionStore.isV1Gated(tool), isFalse);
        expect(
          ToolPermissionStore.defaultFor(tool),
          ToolPermission.allow,
          reason: '$tool must run without an ask prompt',
        );
        expect(registry.isImplemented(tool), isTrue);
      }
    });

    test('send_sms refuses bad input before touching the channel', () async {
      // No recipient / no message: validation fails first, so the
      // SmsManager channel is never called — safe in a unit test, where
      // the channel has no native side.
      for (final params in [
        <String, dynamic>{},
        {'recipient': 'LaKisha'},
        {'message': 'hello'},
        {'recipient': '', 'message': 'hello'},
        {'recipient': 'LaKisha', 'message': ''},
      ]) {
        final result = await registry.executeTool(
          toolName: 'send_sms',
          params: params,
        );
        expect(result.status, ToolStatus.failed);
        expect(result.isSuccess, isFalse);
      }
    });

    test('create_calendar_event refuses bad input before touching the channel',
        () async {
      // Every case here fails in validation — a start time that parses
      // would reach the permission check, and the channel has no native
      // side in a unit test.
      for (final params in [
        <String, dynamic>{},
        {'title': 'Dentist'},
        {'title': 'Dentist', 'start': 'not a time'},
        {'title': '', 'start': '2026-11-17T09:00:00'},
        {
          'title': 'Dentist',
          'start': '2026-11-17T09:00:00',
          'end': '2026-11-17T08:00:00',
        },
      ]) {
        final result = await registry.executeTool(
          toolName: 'create_calendar_event',
          params: params,
        );
        expect(result.status, ToolStatus.failed);
        expect(result.isSuccess, isFalse);
      }
    });

    test('add_contact refuses bad input before touching the channel',
        () async {
      for (final params in [
        <String, dynamic>{},
        {'name': ''},
      ]) {
        final result = await registry.executeTool(
          toolName: 'add_contact',
          params: params,
        );
        expect(result.status, ToolStatus.failed);
        expect(result.isSuccess, isFalse);
      }
    });

    test('set_alarm refuses bad input before touching the channel', () async {
      for (final params in [
        <String, dynamic>{},
        {'time': 'not a time'},
        {'time': '25:00'},
        {'time': '7:5'},
        {'time': ''},
      ]) {
        final result = await registry.executeTool(
          toolName: 'set_alarm',
          params: params,
        );
        expect(result.status, ToolStatus.failed);
        expect(result.isSuccess, isFalse);
      }
    });
  });

  group('generate_on_site (build #114)', () {
    test('the tool is registered, implemented, and offered to the model',
        () {
      final def = registry.tools['generate_on_site']!;
      expect(def.implemented, isTrue);
      expect(def.required, containsAll(['site', 'kind', 'prompt']));
      expect(
        registry.toolsForModel.map((t) => t.name),
        contains('generate_on_site'),
      );
    });

    test('defaults to Ask and is never silent', () {
      expect(
        ToolPermissionStore.defaultFor('generate_on_site'),
        ToolPermission.ask,
      );
      expect(ToolPermissionStore.isSilent('generate_on_site'), isFalse);
    });

    test('never runs on a cloud turn', () {
      expect(ToolRegistry.isCloudFileTool('generate_on_site'), isFalse);
    });

    test('a non-allowlisted site is refused before anything loads',
        () async {
      final result = await registry.executeTool(
        toolName: 'generate_on_site',
        params: {'site': 'youtube', 'kind': 'image', 'prompt': 'a cat'},
      );
      expect(result.status, ToolStatus.failed);
      expect(result.message, contains('refused'));
      expect(result.isSuccess, isFalse);
    });

    test('VideoExpress is refused as unimplemented, not attempted',
        () async {
      final result = await registry.executeTool(
        toolName: 'generate_on_site',
        params: {
          'site': 'videoexpress',
          'kind': 'video',
          'prompt': 'a clip',
        },
      );
      expect(result.status, ToolStatus.unsupported);
      expect(result.isSuccess, isFalse);
    });

    test('a non-image kind is refused', () async {
      final result = await registry.executeTool(
        toolName: 'generate_on_site',
        params: {'site': 'artistly', 'kind': 'video', 'prompt': 'a clip'},
      );
      expect(result.status, ToolStatus.failed);
      expect(result.isSuccess, isFalse);
    });

    test('missing or empty prompt is refused before touching the browser',
        () async {
      for (final params in [
        <String, dynamic>{'site': 'artistly', 'kind': 'image'},
        {'site': 'artistly', 'kind': 'image', 'prompt': ''},
        {'site': 'artistly', 'kind': 'image', 'prompt': '   '},
      ]) {
        final result = await registry.executeTool(
          toolName: 'generate_on_site',
          params: params,
        );
        expect(result.status, ToolStatus.failed);
        expect(result.isSuccess, isFalse);
      }
    });

    test('with no browser controller registered it fails honestly',
        () async {
      BrowserDriver.instance.resetForTest();
      final result = await registry.executeTool(
        toolName: 'generate_on_site',
        params: {'site': 'artistly', 'kind': 'image', 'prompt': 'a cat'},
      );
      expect(result.status, ToolStatus.failed);
      expect(result.message, contains('not ready'));
      expect(result.isSuccess, isFalse);
    });

    test('a Blocked tool is hidden from the model prompt', () async {
      final section = await registry.promptSection(
        blockedTools: {'generate_on_site'},
      );
      expect(section, isNot(contains('generate_on_site')));
      // And unblocked it is offered.
      final open = await registry.promptSection();
      expect(open, contains('generate_on_site'));
    });
  });
}
