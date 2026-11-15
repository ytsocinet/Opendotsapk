/// Tests for the native-trace viewer on the Diagnostics screen (build #99).
///
/// The trace is a cross-language contract: the native glue writes it (the
/// path is set from Kotlin — see scripts/patch_native_llama.py) and this
/// screen reads it. If the two sides disagree on the file name, the
/// section silently shows "No native trace yet" after a failed turn, which
/// is exactly when the trace matters most. These tests pin the name and
/// the path resolution. There is no widget test here on purpose: the repo
/// has no widget-test harness (no test pumps a widget), and the file
/// identity is the part that can break silently.
library;

import 'dart:io';

import 'package:clawzilla/presentation/screens/diagnostics_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('native trace file', () {
    test('the file name matches what the native glue is told to write', () {
      // Kotlin sets "app_flutter/native_trace.log" (the docs dir on
      // Android is <filesDir>/app_flutter). This name is the other half
      // of that path — change one side and the trace never shows up.
      expect(DiagnosticsScreen.traceFileName, 'native_trace.log');
    });

    test('the trace file lives in the documents directory', () async {
      final docs = await Directory.systemTemp.createTemp('clawzilla_diag');
      addTearDown(() async {
        if (docs.existsSync()) await docs.delete(recursive: true);
      });

      final file = DiagnosticsScreen.traceFile(docs);
      expect(file.path, '${docs.path}/native_trace.log');
      expect(file.parent.path, docs.path);
    });

    test('a written trace round-trips through the resolved file', () async {
      final docs = await Directory.systemTemp.createTemp('clawzilla_diag');
      addTearDown(() async {
        if (docs.existsSync()) await docs.delete(recursive: true);
      });

      const trace =
          'generate: entered n_msg=2 n_media=0 draft=0 n_ctx=4096\n'
          'tokenize: 120 prompt tokens\n'
          'prefill: chunk at 0/120 tokens rc=0\n'
          'first token sent\n'
          'eos: stream closed, tokens_sent=42\n';
      final file = DiagnosticsScreen.traceFile(docs);
      await file.writeAsString(trace);

      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), trace);
    });
  });
}
