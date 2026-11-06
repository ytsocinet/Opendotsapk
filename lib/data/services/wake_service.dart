/// Cypher wake mode: "Hey Cypher" always-listening (Porcupine) plus the
/// foreground service that keeps it alive with the app closed.
///
/// Two things the code cannot conjure on its own, and reports plainly
/// instead of failing silently:
/// * The Picovoice AccessKey — the user saves it in Settings → Voice; it
///   lives in the Android Keystore and never in the repo (the fork is
///   public).
/// * The "Hey Cypher" keyword file (`assets/hey_cypher.ppn`) — trained in
///   the Picovoice Console and shipped in the app assets. Until it exists,
///   starting always-listening reports that it is missing.
///
/// All audio stays on the phone: Porcupine only answers "did someone say
/// the magic words?" and the speech recogniser only runs after it hears
/// them. The foreground service shows a persistent "Cypher is listening"
/// notification while it runs, and stopping it (the Settings toggle) stops
/// the mic entirely.
library;

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

import '../../core/utils/log.dart';
import 'secure_store.dart';

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
  void onReceiveData(Object data) {}

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

  /// Asset path of the trained "Hey Cypher" keyword file. It is bundled
  /// once it exists; until then [start] reports it missing.
  static const String keywordAsset = 'assets/hey_cypher.ppn';

  static const String wakePhrase = 'Hey Cypher';

  PorcupineManager? _porcupine;
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
    final key = await SecureStore.instance.apiKey('picovoice');
    if (key == null || key.trim().isEmpty) {
      return 'Add your Picovoice key in Settings → Voice first.';
    }
    try {
      await rootBundle.load(keywordAsset);
    } catch (_) {
      return 'The "Hey Cypher" keyword file is not installed yet.';
    }
    try {
      await _startForegroundService();
      _porcupine = await PorcupineManager.fromKeywordPaths(
        key,
        [keywordAsset],
        _onWakeWord,
        sensitivities: [0.5],
        errorCallback: (e) => Log.w('wake word error: ${e.message}'),
      );
      await _porcupine!.start();
      _running = true;
      Log.i('Cypher always-listening on');
      return null;
    } on PorcupineException catch (e) {
      await _stopForegroundService();
      return 'Could not start listening: ${e.message}';
    } catch (e) {
      await _stopForegroundService();
      return 'Could not start listening: $e';
    }
  }

  Future<void> stop() async {
    if (!_running && !_serviceRunning) return;
    try {
      await _porcupine?.stop();
    } catch (_) {}
    try {
      await _porcupine?.delete();
    } catch (_) {}
    _porcupine = null;
    _running = false;
    await _stopForegroundService();
    Log.i('Cypher always-listening off');
  }

  void _onWakeWord(int keywordIndex) {
    Log.i('wake word heard: $wakePhrase');
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
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
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
    await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'Cypher is listening',
      notificationText: 'Say "Hey Cypher" to talk',
      callback: cypherWakeTaskCallback,
    );
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
