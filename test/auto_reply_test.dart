/// Build #123: auto-reply — sender normalisation, rule matching, all
/// §3 guards (master-off, short-code refusal, cooldown, in-call,
/// own-number), template passthrough unchanged, idempotency on
/// redelivery, and a real-database round-trip for the rules table.
///
/// The service tests use an in-memory fake store, so they never touch a
/// real database and never touch a platform channel: the sender, the
/// in-call check, the SMS-permission check, and the logger are all
/// injected. The last group opens the real [DatabaseHelper] through
/// `sqflite_common_ffi` (a dev-only dependency), mirroring
/// `persona_test.dart`. No model, no network, no keys in these tests.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:clawzilla/data/database/database_helper.dart';
import 'package:clawzilla/data/services/auto_reply_service.dart';
import 'package:clawzilla/domain/models/auto_reply_rule.dart';
import 'package:clawzilla/domain/models/tool_result.dart';
import 'package:clawzilla/presentation/providers/auto_reply_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// In-memory [AutoReplyStore]: insertion-ordered rules, plain prefs.
class FakeAutoReplyStore implements AutoReplyStore {
  final Map<String, AutoReplyRule> rules = {};
  final Map<String, String> prefs = {};

  @override
  Future<List<Map<String, dynamic>>> getAutoReplyRules() async =>
      [for (final r in rules.values) r.toMap()];

  @override
  Future<void> insertAutoReplyRule(AutoReplyRule rule) async {
    rules[rule.id] = rule;
  }

  @override
  Future<void> updateAutoReplyRule(AutoReplyRule rule) async {
    rules[rule.id] = rule;
  }

  @override
  Future<int> deleteAutoReplyRule(String id) async =>
      rules.remove(id) == null ? 0 : 1;

  @override
  Future<String?> getPreference(String key) async => prefs[key];
}

AutoReplyRule _rule({
  String id = 'rule-1',
  String name = 'Shannon',
  String number = '+1 (555) 123-4567',
  bool enabled = true,
  String template = "Hey, I'm busy — I'll get back to you. - Aaron",
  DateTime? lastRepliedAt,
}) {
  final now = DateTime.utc(2026, 11, 19, 12);
  return AutoReplyRule(
    id: id,
    contactName: name,
    phoneNumber: number,
    enabled: enabled,
    mode: 'template',
    templateText: template,
    lastRepliedAt: lastRepliedAt,
    createdAt: now,
    updatedAt: now,
  );
}

/// A store with the master on, a 30-minute cooldown, and no own number
/// — the "everything allowed" baseline each service test starts from.
FakeAutoReplyStore _openStore() {
  final store = FakeAutoReplyStore();
  store.prefs['auto_reply_enabled'] = 'true';
  store.prefs['auto_reply_cooldown_minutes'] = '30';
  return store;
}

void main() {
  group('normalizePhoneNumber', () {
    test('strips formatting and keeps the country code', () {
      expect(normalizePhoneNumber('+1 (555) 123-4567'), '15551234567');
      expect(normalizePhoneNumber('+44 20 7946 0958'), '442079460958');
    });

    test('leaves bare digits alone and drops an empty string to empty', () {
      expect(normalizePhoneNumber('5551234567'), '5551234567');
      expect(normalizePhoneNumber(''), '');
    });
  });

  group('AutoReplyRule model', () {
    test('toMap/fromMap round-trips a rule', () {
      final rule = _rule();
      final restored = AutoReplyRule.fromMap(rule.toMap());
      expect(restored.id, rule.id);
      expect(restored.contactName, rule.contactName);
      expect(restored.phoneNumber, rule.phoneNumber);
      expect(restored.enabled, isTrue);
      expect(restored.mode, 'template');
      expect(restored.templateText, rule.templateText);
      expect(restored.lastRepliedAt, isNull);
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        rule.createdAt.millisecondsSinceEpoch,
      );
    });

    test('copyWith changes only the named fields', () {
      final rule = _rule();
      final renamed = rule.copyWith(contactName: 'Shan');
      expect(renamed.contactName, 'Shan');
      expect(renamed.id, rule.id);
      expect(renamed.phoneNumber, rule.phoneNumber);
      expect(renamed.templateText, rule.templateText);
    });
  });

  group('evaluateAutoReply (pure guards)', () {
    const now = 1794000000000;

    AutoReplyEvaluation evaluate({
      bool master = true,
      List<AutoReplyRule> rules = const [],
      String sender = '15551234567',
      String myNumber = '',
      int cooldownMinutes = 30,
    }) => evaluateAutoReply(
      masterEnabled: master,
      rules: rules,
      sender: sender,
      myNumber: myNumber,
      cooldownMinutes: cooldownMinutes,
      nowMillis: now,
    );

    test('matches a rule across formatting differences', () {
      final result = evaluate(rules: [_rule()]);
      expect(result.shouldReply, isTrue);
      expect(result.rule?.id, 'rule-1');
    });

    test('a sender with no rule never replies', () {
      final result = evaluate(rules: [_rule()], sender: '15559876543');
      expect(result.shouldReply, isFalse);
      expect(result.skipReason, AutoReplySkipReason.noRule);
    });

    test('a disabled rule matches nothing', () {
      final result = evaluate(
        rules: [_rule(enabled: false)],
      );
      expect(result.shouldReply, isFalse);
      expect(result.skipReason, AutoReplySkipReason.noRule);
    });

    test('master off kills everything, even a matching rule', () {
      final result = evaluate(master: false, rules: [_rule()]);
      expect(result.shouldReply, isFalse);
      expect(result.skipReason, AutoReplySkipReason.masterOff);
    });

    test('short codes never reply, even when they match a rule', () {
      final result = evaluate(
        rules: [_rule(number: '55512')],
        sender: '55512',
      );
      expect(result.shouldReply, isFalse);
      expect(result.skipReason, AutoReplySkipReason.shortCode);
    });

    test('a 6-digit sender is a short code; 7 digits is not', () {
      expect(
        evaluate(
          rules: [_rule(number: '555123')],
          sender: '555123',
        ).skipReason,
        AutoReplySkipReason.shortCode,
      );
      expect(
        evaluate(
          rules: [_rule(number: '5551234')],
          sender: '5551234',
        ).shouldReply,
        isTrue,
      );
    });

    test('cooldown blocks a second reply inside the window', () {
      final recent = _rule(
        lastRepliedAt: DateTime.fromMillisecondsSinceEpoch(
          now - 5 * 60 * 1000,
        ),
      );
      final blocked = evaluate(rules: [recent]);
      expect(blocked.shouldReply, isFalse);
      expect(blocked.skipReason, AutoReplySkipReason.cooldown);

      final old = _rule(
        lastRepliedAt: DateTime.fromMillisecondsSinceEpoch(
          now - 31 * 60 * 1000,
        ),
      );
      expect(evaluate(rules: [old]).shouldReply, isTrue);

      final never = _rule();
      expect(evaluate(rules: [never]).shouldReply, isTrue);
    });

    test('the cooldown window follows the stored minutes', () {
      final replied20MinAgo = _rule(
        lastRepliedAt: DateTime.fromMillisecondsSinceEpoch(
          now - 20 * 60 * 1000,
        ),
      );
      expect(
        evaluate(
          rules: [replied20MinAgo],
          cooldownMinutes: 10,
        ).shouldReply,
        isTrue,
      );
      expect(
        evaluate(
          rules: [replied20MinAgo],
          cooldownMinutes: 30,
        ).shouldReply,
        isFalse,
      );
    });

    test('never replies to his own number', () {
      final result = evaluate(
        rules: [_rule()],
        sender: '+1 (555) 123-4567',
        myNumber: '15551234567',
      );
      expect(result.shouldReply, isFalse);
      expect(result.skipReason, AutoReplySkipReason.ownNumber);
    });

    test('an empty own-number setting disables the own-number guard', () {
      final result = evaluate(rules: [_rule()], myNumber: '');
      expect(result.shouldReply, isTrue);
    });
  });

  group('AutoReplyService.handleIncoming', () {
    late FakeAutoReplyStore store;
    late List<(String, String)> sent;
    late List<({String tool, Map<String, dynamic> params, String result})>
    logged;
    late bool inCall;
    late bool smsGranted;
    late bool sendSucceeds;

    AutoReplyService service() => AutoReplyService(
      store: store,
      sendSms: ({required String recipient, required String message}) async {
        sent.add((recipient, message));
        return sendSucceeds;
      },
      isInCall: () async => inCall,
      smsPermissionGranted: () async => smsGranted,
      logToolCall: ({
        required String toolName,
        required Map<String, dynamic> params,
        required ToolResult result,
        required String permissionLevel,
      }) async {
        logged.add((
          tool: toolName,
          params: params,
          result: result.toJson(),
        ));
      },
    );

    setUp(() {
      store = _openStore();
      sent = [];
      logged = [];
      inCall = false;
      smsGranted = true;
      sendSucceeds = true;
    });

    test('sends the template verbatim and stamps the cooldown', () async {
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '+1 (555) 123-4567',
        body: 'hey are you free tonight?',
        timestamp: 1794000000000,
      );

      expect(result.replied, isTrue);
      expect(result.handled, isTrue);
      expect(sent.length, 1);
      // The recipient is the rule's stored number; the message is the
      // template exactly as Aaron wrote it — no model, no rewrite.
      expect(sent.single.$1, '+1 (555) 123-4567');
      expect(
        sent.single.$2,
        "Hey, I'm busy — I'll get back to you. - Aaron",
      );
      final updated = store.rules['rule-1']!;
      expect(updated.lastRepliedAt, isNotNull);
      // The log records what was sent, to whom, under which rule — and
      // never the incoming body.
      expect(logged.length, 1);
      expect(logged.single.tool, 'auto_reply');
      expect(logged.single.params['recipient'], '+1 (555) 123-4567');
      expect(logged.single.params['rule_id'], 'rule-1');
      expect(logged.single.params['contact_name'], 'Shannon');
      expect(logged.single.result, contains('success'));
      expect(logged.single.params.toString(), isNot(contains('free tonight')));
      expect(logged.single.result, isNot(contains('free tonight')));
    });

    test('master off sends nothing', () async {
      store.prefs['auto_reply_enabled'] = 'false';
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.masterOff);
      expect(sent, isEmpty);
      expect(logged, isEmpty);
    });

    test('unknown sender sends nothing', () async {
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15559876543',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.noRule);
      expect(sent, isEmpty);
    });

    test('short-code sender sends nothing', () async {
      store.rules['rule-1'] = _rule(number: '55512');
      final result = await service().handleIncoming(
        sender: '55512',
        body: 'Your code is 123456',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.shortCode);
      expect(sent, isEmpty);
    });

    test('second message inside the cooldown sends nothing', () async {
      store.rules['rule-1'] = _rule();
      final svc = service();
      final first = await svc.handleIncoming(
        sender: '15551234567',
        body: 'first',
        timestamp: 1794000000000,
      );
      expect(first.replied, isTrue);
      final second = await svc.handleIncoming(
        sender: '15551234567',
        body: 'second',
        timestamp: 1794000001000,
      );
      expect(second.replied, isFalse);
      expect(second.skipReason, AutoReplySkipReason.cooldown);
      expect(sent.length, 1);
    });

    test('after the window passes, the same sender gets a reply', () async {
      final old = DateTime.now().subtract(const Duration(minutes: 31));
      store.rules['rule-1'] = _rule(lastRepliedAt: old);
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'again',
        timestamp: 1794000000000,
      );
      expect(result.replied, isTrue);
      expect(sent.length, 1);
    });

    test('in a call sends nothing', () async {
      inCall = true;
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.inCall);
      expect(sent, isEmpty);
    });

    test('own number sends nothing', () async {
      store.prefs['my_phone_number'] = '+1 (555) 123-4567';
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.ownNumber);
      expect(sent, isEmpty);
    });

    test('missing SMS permission sends nothing', () async {
      smsGranted = false;
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.skipReason, AutoReplySkipReason.smsPermission);
      expect(sent, isEmpty);
    });

    test('a failed send does not stamp the cooldown', () async {
      sendSucceeds = false;
      store.rules['rule-1'] = _rule();
      final result = await service().handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(result.replied, isFalse);
      expect(result.handled, isFalse);
      expect(result.skipReason, AutoReplySkipReason.sendFailed);
      expect(store.rules['rule-1']!.lastRepliedAt, isNull);
      expect(logged.length, 1);
      expect(logged.single.result, contains('failed'));
    });

    test('redelivery of the same message sends once', () async {
      store.rules['rule-1'] = _rule();
      final svc = service();
      final first = await svc.handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      final second = await svc.handleIncoming(
        sender: '15551234567',
        body: 'hi',
        timestamp: 1794000000000,
      );
      expect(first.replied, isTrue);
      expect(second.replied, isFalse);
      expect(second.skipReason, AutoReplySkipReason.duplicate);
      expect(sent.length, 1);
    });
  });

  group('AutoReplyRulesNotifier with a fake store', () {
    test('create, toggle, update, delete', () async {
      final notifier = AutoReplyRulesNotifier(store: FakeAutoReplyStore());
      await notifier.initialized;
      expect(notifier.state, isEmpty);

      final created = await notifier.createRule(
        contactName: 'Shannon',
        phoneNumber: '+1 (555) 123-4567',
        templateText: "I'm busy.",
      );
      expect(notifier.state.length, 1);
      expect(created.mode, 'template');
      expect(created.enabled, isTrue);

      expect(await notifier.setRuleEnabled(created.id, false), isTrue);
      expect(notifier.state.single.enabled, isFalse);
      expect(await notifier.setRuleEnabled(created.id, true), isTrue);

      expect(
        await notifier.updateRule(
          created.copyWith(templateText: 'Call you back soon.'),
        ),
        isTrue,
      );
      expect(notifier.state.single.templateText, 'Call you back soon.');

      expect(await notifier.deleteRule(created.id), isTrue);
      expect(notifier.state, isEmpty);
      expect(await notifier.deleteRule(created.id), isFalse);
      expect(await notifier.updateRule(created), isFalse);
    });
  });

  group('DatabaseHelper auto-reply rules (real database)', () {
    setUpAll(() {
      sqfliteFfiInit();
      // Stock Ubuntu ships only the versioned runtime library
      // (`libsqlite3.so.0`); the unversioned `libsqlite3.so` the loader
      // looks for by default exists only with libsqlite3-dev installed.
      // Point the loader at the runtime library so the test works on a
      // plain install — local VM and CI alike.
      databaseFactory = createDatabaseFactoryFfi(ffiInit: () {
        open.overrideFor(
          OperatingSystem.linux,
          () => DynamicLibrary.open('libsqlite3.so.0'),
        );
      });
    });

    Future<void> deleteDbFile() async {
      await DatabaseHelper.instance.close();
      final dir = await getDatabasesPath();
      final file = File(p.join(dir, 'clawzilla.db'));
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final sidecar = File('${file.path}$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
    }

    setUp(deleteDbFile);
    tearDown(deleteDbFile);

    test('fresh open creates the rules table; CRUD round-trips', () async {
      final db = DatabaseHelper.instance;

      // Fresh database: no rules yet, and the table exists.
      expect(await db.getAutoReplyRules(), isEmpty);

      final rule = _rule();
      await db.insertAutoReplyRule(rule);
      final rows = await db.getAutoReplyRules();
      expect(rows.length, 1);
      final restored = AutoReplyRule.fromMap(rows.first);
      expect(restored.id, rule.id);
      expect(restored.contactName, rule.contactName);
      expect(restored.phoneNumber, rule.phoneNumber);
      expect(restored.enabled, isTrue);
      expect(restored.mode, 'template');
      expect(restored.templateText, rule.templateText);
      expect(restored.lastRepliedAt, isNull);

      // Update lands, and last_replied_at survives the round-trip.
      final stamped = rule.copyWith(
        lastRepliedAt: DateTime.fromMillisecondsSinceEpoch(1794000000000),
      );
      await db.updateAutoReplyRule(stamped);
      final updated = AutoReplyRule.fromMap(
        (await db.getAutoReplyRules()).first,
      );
      expect(updated.lastRepliedAt?.millisecondsSinceEpoch, 1794000000000);

      // Inserting the same id again replaces instead of duplicating.
      await db.insertAutoReplyRule(rule);
      expect((await db.getAutoReplyRules()).length, 1);

      // Delete removes it.
      expect(await db.deleteAutoReplyRule(rule.id), 1);
      expect(await db.getAutoReplyRules(), isEmpty);
      expect(await db.deleteAutoReplyRule(rule.id), 0);
    });

    test('wipe clears the rules table', () async {
      final db = DatabaseHelper.instance;
      await db.insertAutoReplyRule(_rule());
      expect((await db.getAutoReplyRules()).length, 1);
      await db.wipe();
      expect(await db.getAutoReplyRules(), isEmpty);
    });
  });
}
