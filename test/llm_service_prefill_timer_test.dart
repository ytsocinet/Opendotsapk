/// Tests for the split generation timers (build #129, Piece C of the
/// local hang fix — make the timer honest).
///
/// The old single 90s silence bound fired mid-prefill on every
/// normal-mode turn: measured on the phone Nov 20, prefill runs ~512
/// tokens per ~44s (~11.6 tok/s), so a 1,432-token prompt needs
/// ~120–130s before the first token. The split is the fix: a generous
/// prefill bound before the first token, the 90s silence bound only
/// after decoding starts, and a total ceiling that still leaves room
/// for a full slow turn. If the prefill bound ever collapses back to
/// 90s, the hang comes back the moment the prompt grows — so the
/// numbers are pinned here, not just documented.
///
/// Also pins the prefill-progress parser: the poller reads prefill-chunk
/// lines out of the native trace, and the last chunk line in the tail
/// is the progress. The native plugin cannot run in a unit test, so
/// what is pinned here is the pure part.
library;

import 'package:clawzilla/data/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('split generation bounds', () {
    test('prefill bound is 300s — it covers a 1,432-token prompt', () {
      // At the measured ~11.6 tok/s, 1,432 tokens need ~125s; 300s
      // covers ~3,500 tokens with headroom. A 90s prefill bound is
      // the bug itself: it fires mid-prefill on every normal-mode turn.
      expect(LlmService.prefillTimeout, const Duration(seconds: 300));
    });

    test('decode silence bound stays 90s', () {
      // After the first token, 90s without a token means the engine
      // stalled — prefill is done by then, so this is the real
      // "wedged" signal, and it is the only place 90s survives.
      expect(LlmService.decodeSilenceTimeout, const Duration(seconds: 90));
    });

    test('total ceiling leaves room for a full slow turn', () {
      // 300s of prefill plus a full 512-token decode at phone speed
      // runs past the old 5-minute ceiling, which would have fired on
      // a legitimate slow turn. 10 minutes bounds a runaway without
      // ever firing on one.
      expect(LlmService.totalGenerationTimeout, const Duration(minutes: 10));
      expect(
        LlmService.totalGenerationTimeout,
        greaterThan(LlmService.prefillTimeout),
      );
    });

    test('prefill bound is strictly longer than the decode bound', () {
      // The split only works if the two bounds differ: equal bounds
      // would be the old single timer under a new name.
      expect(
        LlmService.prefillTimeout,
        greaterThan(LlmService.decodeSilenceTimeout),
      );
    });
  });

  group('parsePrefillProgress', () {
    test('returns null with no chunk line', () {
      expect(
        LlmService.parsePrefillProgress(
          '[23:30:15.263] tokenize: 1432 prompt tokens\n',
        ),
        isNull,
      );
      expect(LlmService.parsePrefillProgress(''), isNull);
    });

    test('parses one chunk line', () {
      expect(
        LlmService.parsePrefillProgress(
          '[23:30:56.704] prefill: chunk at 0/1432 tokens rc=0\n',
        ),
        (done: 0, total: 1432),
      );
    });

    test('takes the last chunk line in the tail', () {
      // Aaron's Nov 20 trace: chunk 0/1432 at 23:30:56, then
      // 512/1432 at 23:31:40. The newest line is the progress.
      expect(
        LlmService.parsePrefillProgress(
          '[23:30:56.704] prefill: chunk at 0/1432 tokens rc=0\n'
          '[23:31:40.866] prefill: chunk at 512/1432 tokens rc=0\n',
        ),
        (done: 512, total: 1432),
      );
    });

    test('ignores non-chunk lines around the chunks', () {
      expect(
        LlmService.parsePrefillProgress(
          '[23:30:15.246] generate: entered n_msg=2 n_media=0 draft=0 '
          'temp=0.70 top_k=40 top_p=0.90 n_ctx=4096\n'
          '[23:30:15.263] tokenize: 1432 prompt tokens\n'
          '[23:30:56.704] prefill: chunk at 0/1432 tokens rc=0\n'
          '[23:31:40.866] prefill: chunk at 512/1432 tokens rc=0\n',
        ),
        (done: 512, total: 1432),
      );
    });
  });
}
