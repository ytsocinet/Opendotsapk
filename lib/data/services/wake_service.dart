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
import 'package:permission_handler/permission_handler.dart';
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

/// One closed wake-word utterance's peak readings, for the Activity log.
/// Returned by [WakeCalibrationTracker.onScore] when a score run above
/// [WakeCalibrationTracker.peakLogThreshold] ends.
class WakePeakEvent {
  const WakePeakEvent({required this.peakScore, required this.micPeak});

  /// Highest classifier score in the utterance (0–1).
  final double peakScore;

  /// Highest raw mic level in the utterance (0–1, before gain).
  final double micPeak;
}

/// Pure calibration logic for wake mode (build #131): tracks the live
/// classifier score, the raw mic level, per-utterance peaks and stream
/// liveness, with no dependency on the plugin — so it is unit-testable
/// without a microphone. The service feeds it from the detector's
/// `rawScores` / `audioLevel` streams; the Diagnostics screen renders it.
class WakeCalibrationTracker {
  /// A score at or above this opens an "utterance" whose peak gets
  /// logged when the score falls back below it. Well under the 0.30
  /// detection threshold, so near-misses are caught too.
  static const double peakLogThreshold = 0.10;

  /// No audio chunk for this long while wake claims to be running means
  /// the record stream died silently — that alone is a diagnosis.
  static const Duration streamDeadAfter = Duration(seconds: 5);

  /// Scores are kept for this long for the history strip.
  static const Duration historyWindow = Duration(seconds: 10);

  int classifierCalls = 0;
  double lastScore = 0;
  double lastLevel = 0;
  DateTime? lastChunkAt;
  double lastUtterancePeakScore = 0;
  double lastUtterancePeakMic = 0;

  bool _inUtterance = false;
  double _utterancePeakScore = 0;
  double _utterancePeakMic = 0;
  final List<_ScoredPoint> _recent = [];

  /// Scores from the last [historyWindow], oldest first, for the
  /// history strip. A fresh list each read, so the UI can hold it.
  List<double> get recentScores =>
      List<double>.unmodifiable(_recent.map((p) => p.score));

  /// True once at least one utterance has closed (peaks are >=
  /// [peakLogThreshold], so a zero peak means "none yet").
  bool get hasLastUtterance => lastUtterancePeakScore > 0;

  /// Whether audio chunks are still arriving. False before the first
  /// chunk and once [streamDeadAfter] has passed without one.
  bool isStreamAlive(DateTime now) {
    final last = lastChunkAt;
    return last != null && now.difference(last) < streamDeadAfter;
  }

  /// Time since the last audio chunk, or null if none ever arrived.
  Duration? secondsSinceLastChunk(DateTime now) {
    final last = lastChunkAt;
    return last == null ? null : now.difference(last);
  }

  /// Feed one classifier score. Returns a [WakePeakEvent] when a score
  /// run above [peakLogThreshold] just ended, otherwise null.
  WakePeakEvent? onScore(double score, DateTime now) {
    classifierCalls++;
    lastScore = score;
    lastChunkAt = now;
    _recent.add(_ScoredPoint(now, score));
    _recent.removeWhere((p) => now.difference(p.time) > historyWindow);
    if (score >= peakLogThreshold) {
      _inUtterance = true;
      if (score > _utterancePeakScore) _utterancePeakScore = score;
      if (lastLevel > _utterancePeakMic) _utterancePeakMic = lastLevel;
      return null;
    }
    if (!_inUtterance) return null;
    _inUtterance = false;
    final event = WakePeakEvent(
      peakScore: _utterancePeakScore,
      micPeak: _utterancePeakMic,
    );
    lastUtterancePeakScore = _utterancePeakScore;
    lastUtterancePeakMic = _utterancePeakMic;
    _utterancePeakScore = 0;
    _utterancePeakMic = 0;
    return event;
  }

  /// Feed one raw mic level (0–1, before gain).
  void onLevel(double level, DateTime now) {
    lastLevel = level;
    lastChunkAt = now;
    if (_inUtterance && level > _utterancePeakMic) {
      _utterancePeakMic = level;
    }
  }

  /// Fresh listening session: counters, peaks and history restart.
  void reset() {
    classifierCalls = 0;
    lastScore = 0;
    lastLevel = 0;
    lastChunkAt = null;
    lastUtterancePeakScore = 0;
    lastUtterancePeakMic = 0;
    _inUtterance = false;
    _utterancePeakScore = 0;
    _utterancePeakMic = 0;
    _recent.clear();
  }
}

class _ScoredPoint {
  const _ScoredPoint(this.time, this.score);
  final DateTime time;
  final double score;
}

/// One live reading of the wake calibration state, for the Diagnostics
/// screen. Built by [WakeService] from its [WakeCalibrationTracker];
/// immutable so the screen can hold the latest one and rebuild from it.
class WakeCalibrationSnapshot {
  const WakeCalibrationSnapshot({
    required this.running,
    required this.score,
    required this.micLevel,
    required this.classifierCalls,
    required this.detections,
    required this.lastChunkAt,
    required this.recentScores,
    required this.hasLastUtterance,
    required this.lastUtterancePeakScore,
    required this.lastUtterancePeakMic,
  });

  /// Whether the detector is running right now.
  final bool running;

  /// Latest classifier score (0–1).
  final double score;

  /// Latest raw mic level (0–1, before gain).
  final double micLevel;

  /// Classifier calls so far this session.
  final int classifierCalls;

  /// Detections so far this session.
  final int detections;

  /// When the last audio chunk arrived, or null if none yet.
  final DateTime? lastChunkAt;

  /// Scores from the last ~10 s, oldest first.
  final List<double> recentScores;

  /// Whether any utterance has closed yet this session.
  final bool hasLastUtterance;

  /// Peak score of the last closed utterance (0 if none yet).
  final double lastUtterancePeakScore;

  /// Peak mic level of the last closed utterance (0 if none yet).
  final double lastUtterancePeakMic;
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
  /// 0.5 is openWakeWord's default, but the hey_cypher model was trained
  /// on synthetic speech (47.2% recall at 0.5) and scores a real voice
  /// lower — 0.3 catches more real utterances. Raise it if it fires on
  /// its own, lower it if it still misses the phrase.
  static const double detectionThreshold = 0.3;

  /// Digital gain applied to raw samples before feature extraction.
  /// 2.0 doubles the amplitude, which helps a normal speaking distance
  /// reach the model. Too high clips and distorts, so this stays modest.
  static const double detectionGain = 2.0;

  WakeWordDetector? _detector;
  StreamSubscription<WakeWordDetection>? _detectionSub;
  bool _running = false;
  bool _serviceRunning = false;

  /// Calibration state (build #131): the pure tracker plus the
  /// subscriptions that feed it from the detector's `rawScores` and
  /// `audioLevel` streams. Subscribing changes nothing about detection
  /// — threshold, gain, model and service are untouched.
  final WakeCalibrationTracker calibration = WakeCalibrationTracker();
  StreamSubscription<double>? _rawScoreSub;
  StreamSubscription<double>? _levelSub;
  final _calibrationController =
      StreamController<WakeCalibrationSnapshot>.broadcast();
  WakeCalibrationSnapshot? _latestCalibration;

  /// Live calibration readings, one per score/level event while wake is
  /// running. The Diagnostics screen subscribes to this.
  Stream<WakeCalibrationSnapshot> get calibrationStream =>
      _calibrationController.stream;

  /// The most recent calibration reading, or null if wake has never
  /// run in this process.
  WakeCalibrationSnapshot? get latestCalibration => _latestCalibration;

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
        gain: detectionGain,
      );
      _detectionSub = _detector!.detections.listen(
        (d) => _onWakeWord(d.score),
      );
      // Calibration (build #131): subscribe to the detector's score and
      // mic-level streams. Both are broadcast, so this adds no load on
      // detection — it only observes. Scores crossing 0.10 close an
      // utterance whose peak is logged to the Activity log.
      calibration.reset();
      _rawScoreSub = _detector!.rawScores.listen((score) {
        final event = calibration.onScore(score, DateTime.now());
        if (event != null) {
          Log.i(
            'wake peak score ${event.peakScore.toStringAsFixed(2)} '
            '(threshold ${detectionThreshold.toStringAsFixed(2)}), '
            'mic peak ${event.micPeak.toStringAsFixed(2)}',
          );
        }
        _emitCalibration();
      });
      _levelSub = _detector!.audioLevel.listen((level) {
        calibration.onLevel(level, DateTime.now());
        _emitCalibration();
      });
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
      await _rawScoreSub?.cancel();
    } catch (_) {}
    _rawScoreSub = null;
    try {
      await _levelSub?.cancel();
    } catch (_) {}
    _levelSub = null;
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

  /// Build one calibration reading from the tracker and publish it to
  /// the Diagnostics screen. Called on every score/level event while
  /// wake is running; the screen holds the latest one.
  void _emitCalibration() {
    final snapshot = WakeCalibrationSnapshot(
      running: _running,
      score: calibration.lastScore,
      micLevel: calibration.lastLevel,
      classifierCalls: calibration.classifierCalls,
      detections: _detector?.detectionCount ?? 0,
      lastChunkAt: calibration.lastChunkAt,
      recentScores: calibration.recentScores,
      hasLastUtterance: calibration.hasLastUtterance,
      lastUtterancePeakScore: calibration.lastUtterancePeakScore,
      lastUtterancePeakMic: calibration.lastUtterancePeakMic,
    );
    _latestCalibration = snapshot;
    if (!_calibrationController.isClosed) {
      _calibrationController.add(snapshot);
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
    // A previous session can leave the native service running while this
    // isolate's flag is false (the service outlives the app). Starting
    // again then throws ServiceAlreadyStartedException. Adopt the
    // running service instead of failing — the detector is loaded fresh
    // below, the service only keeps the notification and process alive.
    if (await FlutterForegroundTask.isRunningService) {
      _serviceRunning = true;
      return;
    }
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
    // Microphone permission (Android 14+): a microphone-type foreground
    // service cannot start without RECORD_AUDIO. Without this check the
    // service's startForeground throws, the service stops itself, and
    // the start times out after 5 seconds with no useful message.
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) {
      mic = await Permission.microphone.request();
    }
    if (!mic.isGranted) {
      throw StateError(
        'Microphone permission is off — wake mode needs it to listen. '
        'Turn on the microphone for Clawzilla in Settings and try again.',
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
