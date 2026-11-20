/// Tests for the local-turn measurement logging (build #126, Piece A of
/// the local hang fix).
///
/// Piece A exists to capture two numbers per local turn — the prompt size
/// and the time to the first token — because those decide whether a slow
/// prefill or a dead engine is behind the 90s timeout. The native plugin
/// cannot run in a unit test, so what is pinned here is the pure part:
/// the prompt-size estimate that the Dart log lines use. It must agree
/// with the turn builder's estimate (same ~4 chars/token rule), or the
/// Dart log and the prompt budget would disagree about the same prompt.
library;

import 'package:clawzilla/data/services/llm_service.dart';
import 'package:clawzilla/core/utils/turn_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('estimateWireTokens', () {
    test('empty wire is zero tokens', () {
      expect(LlmService.estimateWireTokens([]), 0);
    });

    test('counts every message text, system prompt included', () {
      final wire = [
        {'role': 'system', 'text': 'abcd'}, // 4 chars
        {'role': 'user', 'text': 'abcdefgh'}, // 8 chars
      ];
      // 12 chars / 4 chars per token = 3.
      expect(LlmService.estimateWireTokens(wire), 3);
    });

    test('rounds up a partial token', () {
      final wire = [
        {'role': 'user', 'text': 'hello'}, // 5 chars -> 2 tokens
      ];
      expect(LlmService.estimateWireTokens(wire), 2);
    });

    test('matches estimateTokens on the joined text', () {
      final wire = [
        {'role': 'system', 'text': 'You are Cypher. ' * 40},
        {'role': 'user', 'text': 'hello, what is the weather like?'},
      ];
      final joined = wire.map((m) => m['text'] ?? '').join();
      expect(
        LlmService.estimateWireTokens(wire),
        estimateTokens(joined),
      );
    });

    test('a full normal-mode prompt estimates in the expected range', () {
      // A normal-mode system prompt (memories + skills + tools) runs to
      // roughly 1,300-1,700 tokens; a safe-mode one is ~100. If this
      // estimate ever stops agreeing with the turn builder, the Dart log
      // lines from Piece A mislead the diagnosis they exist to support.
      final systemPrompt = 'x' * 6000; // ~1,500 tokens
      final wire = [
        {'role': 'system', 'text': systemPrompt},
        {'role': 'user', 'text': 'hello'},
      ];
      final estimate = LlmService.estimateWireTokens(wire);
      expect(estimate, greaterThan(1000));
      expect(estimate, lessThan(2000));
    });
  });
}
