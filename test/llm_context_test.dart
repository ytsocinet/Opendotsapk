/// Regression tests for the local context window (build #99).
///
/// Safe mode works but the full local prompt kills every turn: the model
/// loads, the native prefill fails silently, and the turn times out after
/// 90 seconds with no token. The prompt (saved memories, core skills,
/// tools section) plus history was starving the 2048-token context, so
/// the default was raised to 4096. This pins that default: if it is ever
/// lowered again, the safe-mode-off timeout comes back with it.
library;

import 'package:clawzilla/data/services/llm_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('default context size', () {
    test('the default context is 4096, not 2048', () {
      expect(LlmService.defaultContextSize, 4096);
    });

    test('the default leaves room for the full prompt plus history', () {
      // The full local system prompt (memories + skills + tools) runs to
      // roughly 1500 estimated tokens; 2048 left almost nothing for the
      // question, history, or the reply reserve. 4096 keeps that prompt
      // plus a working margin. If this bound ever moves, re-check the
      // turn builder budget (it uses this as the token budget) and the
      // native prefill failure mode it guards.
      expect(LlmService.defaultContextSize, greaterThan(2048));
    });
  });
}
