/// The side-button / digital-assistant launch channel.
///
/// When Aaron long-presses the side button with Clawzilla picked as the
/// Digital assistant, Android opens the app through the `clawzilla://talk`
/// deep link. MainActivity notes that launch in a MethodChannel
/// (`clawzilla/assistant`); the chat screen asks here, once, whether a
/// "start listening" launch is pending, and if so starts the mic straight
/// away — "Talk to Cypher" with no extra tap.
///
/// The flag is consumed, not just read: checking it clears it, so a
/// resume after the launch does not re-trigger listening.
///
/// When the app is already in the foreground, MainActivity instead calls
/// back through [setListenHandler] the moment the launch lands, so the
/// mic starts without waiting for the next resume.
library;

import 'package:flutter/services.dart';

class AssistantLaunch {
  static const MethodChannel _channel = MethodChannel('clawzilla/assistant');

  /// True when the app was just opened from the assistant gesture or the
  /// `clawzilla://talk` deep link and the mic should start listening.
  /// Each call consumes the flag.
  static Future<bool> consumeListenRequest() async {
    try {
      final result = await _channel.invokeMethod<bool>('consumeListenRequest');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Register (or clear, with null) the handler MainActivity calls when
  /// a listen launch lands while the app is already running.
  static void setListenHandler(void Function()? handler) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
    } else {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'listenRequested') handler();
      });
    }
  }
}
