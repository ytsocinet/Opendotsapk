/// Thin Dart wrapper over the `clawzilla/auto_reply` MethodChannel.
///
/// The Kotlin side is a plain FlutterPlugin, so the channel exists in
/// every FlutterEngine — including the WorkManager background engine
/// where the auto-reply task runs. Callers must still treat every call
/// as fallible: the channel is absent in unit tests (inject fakes
/// instead) and a revoked SMS permission fails the send with `"error"`.
library;

import 'package:flutter/services.dart';

/// One device contact, as listed for the add-rule picker.
///
/// [number] is the stored number as the contacts provider holds it
/// (formatting included); the service normalises it to digits before
/// matching or storing a rule.
class AutoReplyContact {
  const AutoReplyContact({required this.name, required this.number});

  final String name;
  final String number;
}

class AutoReplySms {
  static const MethodChannel _channel =
      MethodChannel('clawzilla/auto_reply');

  /// Send [message] to [recipient] (a bare number) with SmsManager — no
  /// composer, no confirmation. Returns true only when the system
  /// accepted the message (`"ok"`). False on any failure, including a
  /// missing SEND_SMS grant; never throws for a send failure.
  static Future<bool> sendSms({
    required String recipient,
    required String message,
  }) async {
    final result = await _channel.invokeMethod<String>('sendSms', {
      'recipient': recipient,
      'message': message,
    });
    return result == 'ok';
  }

  /// True while the phone is in a call (or another app holds the audio
  /// mode in communication). Needs no permission — `AudioManager.mode`
  /// is readable by any app — so this works from the background isolate
  /// too.
  static Future<bool> isInCall() async {
    final result = await _channel.invokeMethod<bool>('isInCall');
    return result ?? false;
  }

  /// Device contacts with a phone number, name-sorted, deduplicated by
  /// normalised number. Needs READ_CONTACTS; throws [PlatformException]
  /// with code `permission_denied` when it is not granted.
  static Future<List<AutoReplyContact>> listContacts() async {
    final result =
        await _channel.invokeMethod<List<dynamic>>('listContacts');
    if (result == null) return const [];
    return result.map((entry) {
      final map = Map<String, dynamic>.from(entry as Map);
      return AutoReplyContact(
        name: '${map['name'] ?? ''}',
        number: '${map['number'] ?? ''}',
      );
    }).toList();
  }
}
