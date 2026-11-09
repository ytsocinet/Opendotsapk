/// Cypher wake mode: "Hey Cypher" always-listening (OpenWakeWord) plus the
/// foreground service that keeps it alive with the app closed.
///
/// No account and no key: OpenWakeWord is open source and runs fully
/// on-device. The only thing the code needs is the trained keyword model
/// (`assets/models/hey_cypher.tflite`) — trained from synthetic speech, no
/// recordings — which ships in the app assets. Until it exists, starting
/// always-listening reports that it is missing.
///
/// All audio stays on the phone: the detector only answers "did someone say
/// the magic words?" and the speech recogniser only runs after it hears
/// them. The foreground service shows a persistent "Cypher is listening"
/// notification while it runs, and stopping it (the Settings toggle) stops
/// the mic entirely.
///
/// (Picovoice Porcupine used to be the engine here. Its signup blocks
/// personal email — company email required, and the login-page Google
/// button did not get a personal account in either — so it was replaced
/// Nov 8, 2026. Nothing in this file talks to Picovoice anymore.)
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wake_word_flutter/wake_word_flutter.dart';

import '../../core/utils/log.dart';

/// Top-level foreground-task callback (must be top-level and entry-point
/// marked). The listening itself runs in the main isolate; this handler
/// only keeps the notification alive.
@pragma('vm:entry-point')
void cypherWakeTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_CypherWakeTaskHandler());
}

class _CypherWakeTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}

class WakeService {
  WakeService._();

  static WakeService? _instance;
  static WakeService get instance => _instance ??= WakeService._();

  /// Asset path of the trained "Hey Cypher" keyword model. It is bundled
  /// once it exists; until then [start] reports it missing.
  static const String modelAsset = 'assets/models/hey_cypher.tflite';

  static const String wakePhrase = 'Hey Cypher';

  /// Score (0–1) the detector needs before it counts as a detection.
  /// 0.5 is openWakeWord's default; raise it if it fires on its own,
  /// lower it if it misses the phrase.
  static const double detectionThreshold = 0.5;

  WakeWordDetector? _detector;
  StreamSubscription<WakeWordDetection>? _detectionSub;
  bool _running = false;
  bool _serviceRunning = false;

  /// True when a wake word was heard while no UI callback was registered
  /// (app backgrounded with the chat screen gone). The chat screen
  /// consumes it on resume.
  bool wakePending = false;

  /// Called on the main isolate when "Hey Cypher" is heard. Set by the
  /// chat screen while it is alive; null when nothing is listening for it.
  void Function()? onWakeWord;

  bool get isRunning => _running;

  /// Start listening. Returns null on success, or a user-facing reason
  /// why it could not start.
  Future<String?> start() async {
    if (_running) return null;
    try {
      await rootBundle.load(modelAsset);
    } catch (_) {
      return 'The "Hey Cypher" listening model is not installed yet.';
    }
    try {
      await _startForegroundService();
      _detector = await WakeWordDetector.loadFromAsset(
        modelAsset,
        threshold: detectionThreshold,
      );
      _detectionSub = _detector!.detections.listen(
        (d) => _onWakeWord(d.score),
      );
      if (!await _detector!.start()) {
        await _stopDetector();
        await _stopForegroundService();
        return 'Microphone permission is off — turn it on for Clawzilla in Settings and try again.';
      }
      _running = true;
      Log.i('Cypher always-listening on');
      return null;
    } catch (e) {
      await _stopDetector();
      await _stopForegroundService();
      return 'Could not start listening: $e';
    }
  }

  Future<void> stop() async {
    if (!_running && !_serviceRunning) return;
    await _stopDetector();
    _running = false;
    await _stopForegroundService();
    Log.i('Cypher always-listening off');
  }

  Future<void> _stopDetector() async {
    try {
      await _detectionSub?.cancel();
    } catch (_) {}
    _detectionSub = null;
    try {
      await _detector?.stop();
    } catch (_) {}
    try {
      await _detector?.dispose();
    } catch (_) {}
    _detector = null;
  }

  void _onWakeWord(double score) {
    Log.i('wake word heard: $wakePhrase (score=${score.toStringAsFixed(2)})');
    if (onWakeWord != null) {
      onWakeWord!();
    } else {
      wakePending = true;
      _updateNotification('Cypher heard you — tap to talk');
    }
  }

  /// The exchange finished; put the notification back to its idle text.
  Future<void> markIdle() async {
    await _updateNotification('Say "Hey Cypher" to talk');
  }

  /// A listen is in progress; say so on the notification.
  Future<void> markListening() async {
    await _updateNotification('Listening…');
  }

  Future<void> _startForegroundService() async {
    // Notification permission first (Android 13+): without it the
    // foreground notification cannot show and the service cannot start.
    // The result is checked — a denied prompt used to fall through and
    // fail later with a cryptic "foreground service did not start".
    var perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      perm = await FlutterForegroundTask.requestNotificationPermission();
    }
    if (perm != NotificationPermission.granted) {
      throw StateError(
        'Notifications are off — wake mode needs them to show the '
        'listening notice. Turn on notifications for Clawzilla in '
        'Settings and try again.',
      );
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cypher_listening',
        channelName: 'Cypher listening',
        channelDescription: 'Shows while Cypher listens for "Hey Cypher".',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    final startResult = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Cypher is listening',
      notificationText: 'Say "Hey Cypher" to talk',
      callback: cypherWakeTaskCallback,
    );
    // startService reports failure as a result, not a throw — read it,
    // or the real reason (e.g. a service timeout) is hidden behind the
    // generic check below.
    if (startResult is ServiceRequestFailure) {
      throw StateError('foreground service failed: ${startResult.error}');
    }
    if (!await FlutterForegroundTask.isRunningService) {
      throw StateError('foreground service did not start');
    }
    _serviceRunning = true;
  }

  Future<void> _updateNotification(String text) async {
    if (!_serviceRunning) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Cypher is listening',
        notificationText: text,
      );
    } catch (_) {}
  }

  Future<void> _stopForegroundService() async {
    if (!_serviceRunning) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    _serviceRunning = false;
  }
}
