/// Auto-reply (build #123, Auto-reply Piece A): template replies to
/// opted-in contacts, sent from the WorkManager background task.
///
/// The flow is: `SmsReceiver` (Kotlin) parses the SMS broadcast and
/// enqueues a one-off WorkManager task; `callbackDispatcher` in
/// `lib/main.dart` hands it to [AutoReplyService.handleIncoming]; this
/// file decides and sends.
///
/// What Piece A deliberately does NOT do (plan §5): the incoming body
/// is never written to `user_memories`, never added to a chat prompt,
/// and never shown in a chat bubble — it arrives as a parameter, is
/// ignored (the template does not need it), and is dropped. The activity
/// log records that a reply was sent, to whom, and under which rule —
/// never the incoming body. There is no inbox anywhere in the app.
///
/// Guards, in order (plan §3, task order): master toggle off → no rule
/// for the sender → short code (fewer than 7 digits) → cooldown (one
/// reply per sender per window) → own number → in a call → SMS
/// permission missing. Group MMS never arrives: the receiver does not
/// register for `WAP_PUSH_RECEIVED`, so group texts never trigger this
/// path at all.
///
/// The guard logic is pure ([normalizePhoneNumber], [evaluateAutoReply])
/// so it is unit-testable with no database and no platform channels.
/// The runner ([AutoReplyService]) takes its store, sender, in-call
/// check, permission check, and logger as constructor arguments, so
/// tests inject fakes; the production defaults are the real ones.
///
/// Sending: the background isolate has no `clawzilla/apps` channel —
/// that channel is registered by MainActivity, which never runs for a
/// WorkManager engine — so the send goes through the local
/// `clawzilla_auto_reply` plugin ([AutoReplySms.sendSms]), whose
/// SmsManager call has the same semantics as the chat path's
/// `send_sms` (multipart, `"ok"` only when the system accepted it).
/// `send_sms` itself and `tool_registry.dart` are untouched.
library;

import 'package:clawzilla_auto_reply/clawzilla_auto_reply.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/log.dart';
import '../../domain/models/auto_reply_rule.dart';
import '../../domain/models/tool_result.dart';
import '../tools/tool_registry.dart';

/// Why a message got no reply. Null (in [AutoReplyEvaluation]) means
/// "reply" — every other outcome names the guard that stopped it, so the
/// activity log and the tests can tell a principled skip from a failure.
enum AutoReplySkipReason {
  /// The master toggle is off.
  masterOff,

  /// No rule matches the sender (or the matching rule is disabled).
  noRule,

  /// The sender has fewer than 7 digits — a short code, never replied to
  /// even if it somehow matches a rule.
  shortCode,

  /// The rule already replied inside the cooldown window.
  cooldown,

  /// The sender is Aaron's own number.
  ownNumber,

  /// The phone is in a call.
  inCall,

  /// SEND_SMS is not granted (revoked after the master was turned on).
  smsPermission,

  /// The send itself failed (SmsManager refused, channel missing).
  sendFailed,

  /// This exact message (sender + timestamp) was already handled.
  duplicate,
}

/// The outcome of the pure guard evaluation: the rule to reply under,
/// or the reason not to.
class AutoReplyEvaluation {
  const AutoReplyEvaluation({required this.rule, required this.skipReason});

  /// Null when [skipReason] is set.
  final AutoReplyRule? rule;

  /// Null when this message should be replied to.
  final AutoReplySkipReason? skipReason;

  bool get shouldReply => skipReason == null && rule != null;
}

/// Strip a phone number down to digits: "+1 (555) 123-4567" becomes
/// "15551234567", "+44 20 7946 0958" becomes "442079460958". Matching is
/// on the digits only, so a contact stored one way still matches a
/// sender delivered another way.
String normalizePhoneNumber(String raw) =>
    raw.replaceAll(RegExp(r'\D'), '');

/// The pure guard evaluation: master, rule match, short code, cooldown,
/// own number — in that order. The in-call check is async (a platform
/// channel), so it runs in [AutoReplyService.handleIncoming] after this
/// returns [AutoReplyEvaluation.shouldReply].
///
/// [nowMillis] is injected (rather than read here) so cooldown tests can
/// pin the clock.
AutoReplyEvaluation evaluateAutoReply({
  required bool masterEnabled,
  required List<AutoReplyRule> rules,
  required String sender,
  required String myNumber,
  required int cooldownMinutes,
  required int nowMillis,
}) {
  if (!masterEnabled) {
    return const AutoReplyEvaluation(
      rule: null,
      skipReason: AutoReplySkipReason.masterOff,
    );
  }

  final senderDigits = normalizePhoneNumber(sender);
  AutoReplyRule? rule;
  for (final candidate in rules) {
    if (!candidate.enabled) continue;
    if (normalizePhoneNumber(candidate.phoneNumber) == senderDigits &&
        senderDigits.isNotEmpty) {
      rule = candidate;
      break;
    }
  }
  if (rule == null) {
    return const AutoReplyEvaluation(
      rule: null,
      skipReason: AutoReplySkipReason.noRule,
    );
  }

  // Short codes never reply, even if one somehow matches a rule.
  if (senderDigits.length < 7) {
    return const AutoReplyEvaluation(
      rule: null,
      skipReason: AutoReplySkipReason.shortCode,
    );
  }

  final windowMs = (cooldownMinutes <= 0 ? 30 : cooldownMinutes) * 60000;
  final lastReplied = rule.lastRepliedAt?.millisecondsSinceEpoch;
  if (lastReplied != null && nowMillis - lastReplied < windowMs) {
    return const AutoReplyEvaluation(
      rule: null,
      skipReason: AutoReplySkipReason.cooldown,
    );
  }

  final myDigits = normalizePhoneNumber(myNumber);
  if (myDigits.isNotEmpty && senderDigits == myDigits) {
    return const AutoReplyEvaluation(
      rule: null,
      skipReason: AutoReplySkipReason.ownNumber,
    );
  }

  return AutoReplyEvaluation(rule: rule, skipReason: null);
}

/// The outcome of [AutoReplyService.handleIncoming]: whether a reply
/// went out, and why not when it did not. [handled] is true whenever
/// the task reached a decision (reply or principled skip) — the
/// WorkManager dispatcher returns it, so a skip is a successful task,
/// not a retry.
class AutoReplyResult {
  const AutoReplyResult({
    required this.handled,
    required this.replied,
    required this.skipReason,
  });

  final bool handled;
  final bool replied;
  final AutoReplySkipReason? skipReason;
}

/// Runs one incoming message through the guards and, when they all
/// pass, sends the rule's template.
///
/// The template is sent unchanged, word for word — Piece A has no
/// model-composed replies (that is Piece B). The incoming body is
/// accepted and dropped: nothing in Piece A reads it, stores it, or
/// logs it.
class AutoReplyService {
  AutoReplyService({
    required AutoReplyStore store,
    Future<bool> Function({
      required String recipient,
      required String message,
    })? sendSms,
    Future<bool> Function()? isInCall,
    Future<bool> Function()? smsPermissionGranted,
    Future<void> Function({
      required String toolName,
      required Map<String, dynamic> params,
      required ToolResult result,
      required String permissionLevel,
    })? logToolCall,
  })  : _store = store,
        _sendSms = sendSms ?? AutoReplySms.sendSms,
        _isInCall = isInCall ?? AutoReplySms.isInCall,
        _smsPermissionGranted =
            smsPermissionGranted ?? _defaultSmsPermissionGranted,
        _logToolCall = logToolCall ?? ToolRegistry.logToolCall;

  final AutoReplyStore _store;
  final Future<bool> Function({
    required String recipient,
    required String message,
  }) _sendSms;
  final Future<bool> Function() _isInCall;
  final Future<bool> Function() _smsPermissionGranted;
  final Future<void> Function({
    required String toolName,
    required Map<String, dynamic> params,
    required ToolResult result,
    required String permissionLevel,
  }) _logToolCall;

  /// Keys of messages already handled by this instance (sender digits +
  /// message timestamp). One reply per incoming message, once: a
  /// redelivered broadcast that reaches this isolate twice sends once.
  /// Cross-process redelivery is deduped earlier, at enqueue time — the
  /// receiver enqueues unique WorkManager work keyed on the same
  /// sender+timestamp with KEEP — and the cooldown bounds any exchange
  /// to one reply per window regardless.
  final Set<String> _handledKeys = {};

  static const String defaultCooldownMinutes = '30';

  /// The production SMS-permission check: status only, never a request.
  /// A background isolate has no Activity to show a permission dialog
  /// in, so requesting here could not succeed; the master toggle asks
  /// for the permission in the foreground when it is turned on, and a
  /// later revoke is caught here as a skip.
  static Future<bool> _defaultSmsPermissionGranted() async {
    try {
      return await Permission.sms.status.isGranted;
    } catch (e) {
      Log.w('auto-reply: SMS permission check failed: $e');
      return false;
    }
  }

  Future<AutoReplyResult> handleIncoming({
    required String sender,
    required String body,
    required int timestamp,
  }) async {
    // `body` is deliberately unused: Piece A replies with the rule's
    // template, which does not need the incoming text, and the text must
    // never be stored or logged. It is a parameter only so the dispatcher
    // signature is stable for Piece B, which will compose from it.

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final handledKey = '${normalizePhoneNumber(sender)}@$timestamp';
    if (_handledKeys.contains(handledKey)) {
      Log.d('auto-reply: duplicate delivery for $handledKey, skipping');
      return const AutoReplyResult(
        handled: true,
        replied: false,
        skipReason: AutoReplySkipReason.duplicate,
      );
    }

    final masterEnabled =
        (await _store.getPreference('auto_reply_enabled')) == 'true';
    final cooldownMinutes =
        int.tryParse(
          await _store.getPreference('auto_reply_cooldown_minutes') ??
              defaultCooldownMinutes,
        ) ??
        30;
    final myNumber =
        await _store.getPreference('my_phone_number') ?? '';
    final rules = (await _store.getAutoReplyRules())
        .map(AutoReplyRule.fromMap)
        .toList();

    final evaluation = evaluateAutoReply(
      masterEnabled: masterEnabled,
      rules: rules,
      sender: sender,
      myNumber: myNumber,
      cooldownMinutes: cooldownMinutes,
      nowMillis: nowMillis,
    );
    if (!evaluation.shouldReply) {
      Log.d(
        'auto-reply: skipping reply to $sender: '
        '${evaluation.skipReason?.name}',
      );
      return AutoReplyResult(
        handled: true,
        replied: false,
        skipReason: evaluation.skipReason,
      );
    }
    final rule = evaluation.rule!;

    // The in-call guard runs here, at send time, not when the message
    // arrived: WorkManager may run minutes later, after a call ends,
    // and a message that arrived mid-call should not be dropped for a
    // call that is already over — nor sent while one is still going.
    if (await _isInCall()) {
      Log.d('auto-reply: skipping reply to $sender: in a call');
      return const AutoReplyResult(
        handled: true,
        replied: false,
        skipReason: AutoReplySkipReason.inCall,
      );
    }

    if (!await _smsPermissionGranted()) {
      Log.w('auto-reply: skipping reply to $sender: SMS not granted');
      return const AutoReplyResult(
        handled: true,
        replied: false,
        skipReason: AutoReplySkipReason.smsPermission,
      );
    }

    _handledKeys.add(handledKey);
    final sent = await _sendSms(
      recipient: rule.phoneNumber,
      message: rule.templateText,
    );
    if (!sent) {
      // Do not update last_replied_at: nothing went out, so a later
      // message (or a WorkManager retry) may still reply.
      _handledKeys.remove(handledKey);
      await _logToolCall(
        toolName: 'auto_reply',
        params: {
          'recipient': rule.phoneNumber,
          'rule_id': rule.id,
          'contact_name': rule.contactName,
        },
        result: ToolResult.failed(
          'Auto-reply to ${rule.contactName} (${rule.phoneNumber}) '
          'could not be sent.',
        ),
        permissionLevel: 'allow',
      );
      return const AutoReplyResult(
        handled: false,
        replied: false,
        skipReason: AutoReplySkipReason.sendFailed,
      );
    }

    // The reply went out: stamp the cooldown and log what was sent —
    // to whom, under which rule — never the incoming body.
    await _store.updateAutoReplyRule(
      rule.copyWith(lastRepliedAt: DateTime.fromMillisecondsSinceEpoch(nowMillis)),
    );
    await _logToolCall(
      toolName: 'auto_reply',
      params: {
        'recipient': rule.phoneNumber,
        'rule_id': rule.id,
        'contact_name': rule.contactName,
      },
      result: ToolResult.success(
        'Sent auto-reply to ${rule.contactName} (${rule.phoneNumber}).',
      ),
      permissionLevel: 'allow',
    );
    return const AutoReplyResult(
      handled: true,
      replied: true,
      skipReason: null,
    );
  }
}
