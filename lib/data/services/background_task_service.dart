/// Background mode: keep Clawzilla alive while Cypher works on a long turn.
///
/// The problem it solves is Android, not the model: once the app is
/// backgrounded (or the screen goes off), the OS may suspend the process
/// mid-reply and a long local-model answer or cloud turn simply stops.
/// This service puts the turn under a foreground service — a persistent
/// "Cypher is working" notification — so the work is allowed to finish,
/// then posts a "done" notification and stops the service again.
///
/// Design, and why it looks like this:
///
/// * Delayed start. Most answers finish in a second or two; flashing a
///   notification for those would be noise. The service only starts if a
///   turn is still running 2 seconds after it began. A quick answer never
///   shows anything, and the completion notification is only posted when
///   the service actually ran.
/// * Ref-counted. `beginWork` / `endWork` bracket one chat turn, and the
///   counter makes overlapping turns safe: the service starts on the first
///   begin and stops when the last turn ends.
/// * One foreground service, shared with wake mode. The
///   flutter_foreground_task plugin manages a single service, and the wake
///   service (microphone type) already owns it when always-listening is on.
///   Starting a second one would throw, so when a service is already
///   running this adopts it — it only changes the notification text — and
///   on finish it hands the text back to wake mode. It never stops a
///   service it did not start. Wake mode itself is untouched by this file.
/// * Its own service when nothing is running: service id 257 (wake uses
///   256), `dataSync` type (the Android type for background work; the
///   manifest declares `microphone|dataSync` on the plugin's service), its
///   own notification channel `cypher_working`.
/// * Completion is a real local notification (flutter_local_notifications,
///   channel `cypher_done`, id 258), not the foreground notification: the
///   foreground one vanishes when the service stops, so it cannot carry
///   the "done" message. Tapping it opens the app.
/// * Notification permission is asked the same way wake mode asks it
///   (FlutterForegroundTask's check/request), and a denial is remembered
///   for the rest of the launch so a turn does not re-prompt every time.
///   No microphone permission is needed here: this service type does not
///   listen.
/// * Failures never break the turn. If the service cannot start (no
///   permission, OS refusal), the reply still streams exactly as before —
///   it just is not protected from being slept. Every failure is logged.
///
/// Battery: the service holds a wake lock and (for cloud turns) a wifi
/// lock only while a task runs, and the Settings entry says so — plus that
/// Android must have battery set to Unrestricted for Clawzilla, or the OS
/// may still kill the work despite the service.
library;

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/utils/log.dart';
import 'wake_service.dart';

/// Top-level foreground-task callback (must be top-level and entry-point
/// marked). The work itself runs in the main isolate; this handler only
/// keeps the notification alive. Mirrors [cypherWakeTaskCallback].
@pragma('vm:entry-point')
void cypherBackgroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundTaskHandler());
}

class _BackgroundTaskHandler extends TaskHandler {
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

class BackgroundTaskService {
  BackgroundTaskService._();

  static BackgroundTaskService? _instance;
  static BackgroundTaskService get instance =>
      _instance ??= BackgroundTaskService._();

  /// How long a turn must run before the service starts. Under this, the
  /// answer was quick and no notification ever appears.
  static const Duration startDelay = Duration(seconds: 2);

  /// Foreground service id. Wake mode uses 256; this one is separate so
  /// the two never collide in logs or in `stopService` calls.
  static const int _serviceId = 257;

  /// Local-notification id for the "done" notice.
  static const int _doneNotificationId = 258;

  static const String _workingChannelId = 'cypher_working';
  static const String _doneChannelId = 'cypher_done';

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _localNotificationsReady = false;

  int _activeTurns = 0;
  Timer? _startTimer;
  bool _serviceRunning = false;
  bool _adoptedService = false;
  bool _notificationDenied = false;

  /// A turn started. Arms the delayed service start; the service itself
  /// only starts if the turn is still running when the timer fires.
  void beginWork() {
    _activeTurns++;
    if (_activeTurns != 1) return;
    _startTimer?.cancel();
    _startTimer = Timer(startDelay, () {
      unawaited(_startService());
    });
  }

  /// A turn ended. When the last turn ends, the service stops and — if it
  /// ran — a completion notification is posted first.
  ///
  /// [stopped] is true when the user hit Stop: the notice says so instead
  /// of claiming the answer finished.
  Future<void> endWork({bool stopped = false}) async {
    if (_activeTurns > 0) _activeTurns--;
    if (_activeTurns > 0) return;
    _startTimer?.cancel();
    _startTimer = null;
    if (!_serviceRunning && !_adoptedService) return;
    if (_adoptedService) {
      _adoptedService = false;
      // The service belongs to wake mode: hand its notification back.
      // Only when wake is actually running — otherwise this would write
      // to a service that is already gone.
      if (WakeService.instance.isRunning) {
        await WakeService.instance.markIdle();
      }
      return;
    }
    await _postDoneNotification(stopped: stopped);
    await _stopService();
  }

  Future<void> _startService() async {
    if (_activeTurns == 0) return;
    try {
      // A service is already running (wake mode): adopt it rather than
      // starting a second one, which throws ServiceAlreadyStartedException.
      // The process is already kept alive; only the status text changes.
      if (await FlutterForegroundTask.isRunningService) {
        _adoptedService = true;
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Cypher is working',
          notificationText: 'Working on your request…',
        );
        Log.i('background mode: adopted running foreground service');
        return;
      }
      // Notification permission first (Android 13+): without it the
      // foreground notification cannot show and the service cannot start.
      // Asked once per launch — a denied prompt used to re-appear on
      // every long turn.
      if (!_notificationDenied) {
        var perm = await FlutterForegroundTask.checkNotificationPermission();
        if (perm != NotificationPermission.granted) {
          perm = await FlutterForegroundTask.requestNotificationPermission();
        }
        if (perm != NotificationPermission.granted) {
          _notificationDenied = true;
          Log.w('background mode: notifications denied — turn unprotected');
          return;
        }
      } else {
        return;
      }
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _workingChannelId,
          channelName: 'Cypher working',
          channelDescription:
              'Shows while Cypher works on a long reply, so Android does not sleep the app.',
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
          // Cloud turns need the network while the screen is off.
          allowWifiLock: true,
        ),
      );
      final startResult = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationTitle: 'Cypher is working',
        notificationText: 'Working on your request…',
        callback: cypherBackgroundTaskCallback,
      );
      // startService reports failure as a result, not a throw — read it,
      // or the real reason is hidden behind the generic check below.
      if (startResult is ServiceRequestFailure) {
        throw StateError('foreground service failed: ${startResult.error}');
      }
      if (!await FlutterForegroundTask.isRunningService) {
        throw StateError('foreground service did not start');
      }
      _serviceRunning = true;
      Log.i('background mode: foreground service started');
    } catch (e) {
      // Never break the turn: the reply still streams, it just is not
      // protected from being slept.
      Log.w('background mode: could not start service: $e');
    }
  }

  Future<void> _stopService() async {
    if (!_serviceRunning) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    _serviceRunning = false;
  }

  Future<void> _ensureLocalNotifications() async {
    if (_localNotificationsReady) return;
    try {
      await _localNotifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _localNotificationsReady = true;
    } catch (e) {
      Log.w('background mode: local notifications unavailable: $e');
    }
  }

  /// Posts the "done" notice. Only called when the service actually ran —
  /// quick turns never started it, so they never post anything.
  Future<void> _postDoneNotification({required bool stopped}) async {
    try {
      await _ensureLocalNotifications();
      if (!_localNotificationsReady) return;
      await _localNotifications.show(
        _doneNotificationId,
        stopped ? 'Cypher stopped' : 'Cypher is done',
        stopped
            ? 'Tap to see what it got done.'
            : 'Tap to see the answer.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _doneChannelId,
            'Cypher finished',
            channelDescription:
                'Posted when Cypher finishes a long task.',
            importance: Importance.high,
          ),
        ),
      );
    } catch (e) {
      Log.w('background mode: could not post done notification: $e');
    }
  }
}
