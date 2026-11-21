/// Tests for the wake calibration tracker (build #131).
///
/// The tracker is pure logic — scores and mic levels in, utterance peaks
/// and stream liveness out — so it is pinned here without a microphone.
/// What matters: a peak is logged only for a real score run above 0.10,
/// the peak is the max (not the last) reading, and "no chunks for 5 s"
/// means the stream died. The Diagnostics screen renders this; it does
/// not decide it.
library;

import 'package:clawzilla/data/services/wake_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 21, 12, 0, 0);

  DateTime at(int millis) => t0.add(Duration(milliseconds: millis));

  group('WakeCalibrationTracker peaks', () {
    test('scores below 0.10 open no utterance and log nothing', () {
      final tracker = WakeCalibrationTracker();
      expect(tracker.onScore(0.05, at(0)), isNull);
      expect(tracker.onScore(0.09, at(80)), isNull);
      expect(tracker.classifierCalls, 2);
      expect(tracker.hasLastUtterance, isFalse);
    });

    test('a score run above 0.10 logs its peak when it ends', () {
      final tracker = WakeCalibrationTracker();
      expect(tracker.onScore(0.12, at(0)), isNull);
      tracker.onLevel(0.30, at(0));
      expect(tracker.onScore(0.20, at(80)), isNull);
      tracker.onLevel(0.42, at(80));
      final event = tracker.onScore(0.04, at(160));
      expect(event, isNotNull);
      expect(event!.peakScore, 0.20);
      expect(event.micPeak, 0.42);
      expect(tracker.lastUtterancePeakScore, 0.20);
      expect(tracker.lastUtterancePeakMic, 0.42);
      expect(tracker.hasLastUtterance, isTrue);
      // The next low score is a new silence, not another utterance.
      expect(tracker.onScore(0.02, at(240)), isNull);
    });

    test('the peak is the max score, not the last one', () {
      final tracker = WakeCalibrationTracker();
      tracker.onScore(0.50, at(0));
      tracker.onScore(0.60, at(80));
      tracker.onScore(0.30, at(160));
      final event = tracker.onScore(0.04, at(240));
      expect(event, isNotNull);
      expect(event!.peakScore, 0.60);
    });

    test('a score of exactly 0.10 opens an utterance', () {
      final tracker = WakeCalibrationTracker();
      expect(tracker.onScore(0.10, at(0)), isNull);
      final event = tracker.onScore(0.05, at(80));
      expect(event, isNotNull);
      expect(event!.peakScore, 0.10);
    });

    test('a long high run logs nothing until it ends', () {
      final tracker = WakeCalibrationTracker();
      expect(tracker.onScore(0.50, at(0)), isNull);
      expect(tracker.onScore(0.60, at(80)), isNull);
      expect(tracker.onScore(0.55, at(160)), isNull);
      final event = tracker.onScore(0.04, at(240));
      expect(event, isNotNull);
      expect(event!.peakScore, 0.60);
    });

    test('mic levels outside an utterance do not raise its peak', () {
      final tracker = WakeCalibrationTracker();
      tracker.onLevel(0.90, at(0));
      tracker.onScore(0.05, at(80));
      tracker.onLevel(0.10, at(160));
      tracker.onScore(0.15, at(240));
      final event = tracker.onScore(0.04, at(320));
      expect(event, isNotNull);
      expect(event!.micPeak, 0.10);
    });
  });

  group('WakeCalibrationTracker liveness', () {
    test('no chunks yet means dead, not alive', () {
      final tracker = WakeCalibrationTracker();
      expect(tracker.isStreamAlive(t0), isFalse);
      expect(tracker.secondsSinceLastChunk(t0), isNull);
    });

    test('alive within 5 s of the last chunk, dead at 5 s', () {
      final tracker = WakeCalibrationTracker();
      tracker.onLevel(0.5, t0);
      expect(tracker.isStreamAlive(at(4000)), isTrue);
      expect(tracker.isStreamAlive(at(4999)), isTrue);
      expect(tracker.isStreamAlive(at(5000)), isFalse);
      expect(tracker.isStreamAlive(at(9000)), isFalse);
      expect(tracker.secondsSinceLastChunk(at(7000))?.inSeconds, 7);
    });

    test('a score counts as a chunk too', () {
      final tracker = WakeCalibrationTracker();
      tracker.onScore(0.01, t0);
      expect(tracker.isStreamAlive(at(4000)), isTrue);
      expect(tracker.isStreamAlive(at(6000)), isFalse);
    });

    test('levels do not count as classifier calls', () {
      final tracker = WakeCalibrationTracker();
      tracker.onLevel(0.5, t0);
      tracker.onLevel(0.6, at(80));
      expect(tracker.classifierCalls, 0);
      expect(tracker.lastLevel, 0.6);
    });
  });

  group('WakeCalibrationTracker history and reset', () {
    test('scores older than 10 s are pruned', () {
      final tracker = WakeCalibrationTracker();
      for (var i = 0; i < 5; i++) {
        tracker.onScore(0.01 * i, t0.add(Duration(seconds: i)));
      }
      expect(tracker.recentScores.length, 5);
      tracker.onScore(0.05, t0.add(const Duration(seconds: 11)));
      // The t0 score is 11 s old (pruned); t0+1 s is exactly 10 s old
      // (kept); the rest plus the new one remain.
      expect(tracker.recentScores.length, 5);
      expect(tracker.recentScores.first, 0.01);
    });

    test('reset clears counters, peaks, history and liveness', () {
      final tracker = WakeCalibrationTracker();
      tracker.onScore(0.50, at(0));
      tracker.onLevel(0.42, at(0));
      tracker.onScore(0.04, at(80));
      expect(tracker.hasLastUtterance, isTrue);
      tracker.reset();
      expect(tracker.classifierCalls, 0);
      expect(tracker.lastScore, 0);
      expect(tracker.lastLevel, 0);
      expect(tracker.lastChunkAt, isNull);
      expect(tracker.hasLastUtterance, isFalse);
      expect(tracker.recentScores, isEmpty);
      expect(tracker.isStreamAlive(at(80)), isFalse);
    });
  });

  group('calibration constants', () {
    test('the peak-log threshold sits well under detection', () {
      expect(WakeCalibrationTracker.peakLogThreshold, 0.10);
      expect(WakeService.detectionThreshold, 0.30);
      expect(
        WakeCalibrationTracker.peakLogThreshold,
        lessThan(WakeService.detectionThreshold),
      );
    });

    test('the stream-dead window is 5 s', () {
      expect(
        WakeCalibrationTracker.streamDeadAfter,
        const Duration(seconds: 5),
      );
    });
  });
}
