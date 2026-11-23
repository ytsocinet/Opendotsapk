/// Tests for the keep-model-loaded fix (build #132).
///
/// Nov 23, 2026: the 12:21 turn worked, every later turn logged
/// "generate: no model/context loaded" and waited out the 300s prefill
/// timeout. Root cause, proven from the plugin source: native_llama's
/// `onDetachedFromEngine` called `disposeLlama()` on process-wide
/// native statics, and the foreground service's background engine
/// attaches the plugin — so stopping the service (which background mode
/// does at the end of every turn over 2s) freed the main session's
/// model while both Dart flags still said loaded.
///
/// The fix has two Dart-side parts, and both are pinned here as pure
/// functions — the native plugin cannot run in a unit test, so what is
/// pinned is the pure part, same rule as the timer tests:
/// * `traceReportsNoModel` — the prefill poller fails the turn at once
///   when the trace says the native generate entry found no model,
///   instead of waiting out the 300s prefill timeout.
/// * `needsReload` — the reload decision: reload exactly when Dart
///   believes a model is loaded (and remembers which file) but native
///   reports nothing loaded.
library;

import 'package:clawzilla/data/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('traceReportsNoModel', () {
    test('true for the native no-model line', () {
      expect(
        LlmService.traceReportsNoModel(
          '[12:25:46.602] generate: no model/context loaded\n',
        ),
        isTrue,
      );
    });

    test('true when the line sits among other trace lines', () {
      // Aaron's Nov 23 trace: a working turn, then the no-model line
      // on the next turn. The poller reads only this turn's tail, so
      // the line in the tail means THIS turn's generate found nothing.
      expect(
        LlmService.traceReportsNoModel(
          '[12:24:37.081] eos: stream closed, tokens_sent=499\n'
          '[12:25:46.602] generate: no model/context loaded\n',
        ),
        isTrue,
      );
    });

    test('false with no no-model line', () {
      expect(
        LlmService.traceReportsNoModel(
          '[12:21:44.646] tokenize: 1439 prompt tokens\n'
          '[12:23:04.737] prefill: chunk at 0/1439 tokens rc=0\n'
          '[12:23:38.712] prefill: chunk at 1024/1439 tokens rc=0\n'
          '[12:23:38.717] first token sent\n',
        ),
        isFalse,
      );
      expect(LlmService.traceReportsNoModel(''), isFalse);
    });

    test('false for other generate lines', () {
      // "generate: entered" is the healthy entry line — a turn that
      // reached it has a model. Only the no-model line fails fast.
      expect(
        LlmService.traceReportsNoModel(
          '[12:21:44.609] generate: entered n_msg=2 n_media=0 draft=0 '
          'temp=0.70 top_k=40 top_p=0.90 n_ctx=4096\n',
        ),
        isFalse,
      );
    });
  });

  group('needsReload', () {
    test('reload when Dart thinks loaded but native reports none', () {
      // The Nov 23 shape: _isLoaded true, a remembered path, native
      // empty after a background engine's detach disposed the model.
      expect(
        LlmService.needsReload(
          dartLoaded: true,
          modelPath: '/storage/llm/LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf',
          nativeLoaded: false,
        ),
        isTrue,
      );
    });

    test('no reload when native agrees the model is loaded', () {
      // The already-loaded path: one cheap probe per turn, no load.
      expect(
        LlmService.needsReload(
          dartLoaded: true,
          modelPath: '/storage/llm/LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf',
          nativeLoaded: true,
        ),
        isFalse,
      );
    });

    test('no reload when Dart never loaded anything', () {
      // Fresh start with no model: the _isLoaded check throws first;
      // there is nothing to reload.
      expect(
        LlmService.needsReload(
          dartLoaded: false,
          modelPath: '/storage/llm/LFM3-1.7B-Uncensored-AD-Q4_K_M.gguf',
          nativeLoaded: false,
        ),
        isFalse,
      );
    });

    test('no reload when Dart loaded but remembers no path', () {
      // Cannot reload a model with no file to load from; the caller
      // fails fast instead.
      expect(
        LlmService.needsReload(
          dartLoaded: true,
          modelPath: null,
          nativeLoaded: false,
        ),
        isFalse,
      );
    });
  });
}
