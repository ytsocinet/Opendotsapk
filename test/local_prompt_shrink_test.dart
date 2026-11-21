/// Tests for the local prompt shrink (build #130, Piece D of the local
/// hang fix).
///
/// The numbers that size this piece, all from Aaron's phone: a normal-mode
/// prompt is ~1,393-1,468 tokens (the ~1,400-token system prompt is the
/// bulk), safe mode is ~49 tokens, and prefill runs ~11.6 tok/s — so a
/// full prompt needs ~120-130s. The tools section alone is ~990 tokens
/// by the app's own ~4 chars/token estimate, and most turns never call
/// a tool. So plain chat turns carry a compact names-only tools section
/// (~200 tokens) and only turns that look like tool jobs carry the full
/// one. The saving is pinned here in tokens, not guessed: the compact
/// section must stay under 250 tokens and the cut must exceed 700.
///
/// What is NOT cut, and why: the memories cap (30 entries / 2000 chars)
/// is already the guard, and the measurements show memories contribute
/// ~0 tokens on Aaron's current prompt — cutting the cap would save
/// nothing and lose recall. The core skills (~314 tokens) are behavioral
/// rules for every answer, not a tool list, so they stay. Threads stay
/// at 4 — that is the S23 FE's big-core count, verified, not a guess.
/// The n_batch 512 -> 1024 change lives in scripts/patch_native_llama.py
/// and is measured on-phone via the trace chunk lines, not here.
library;

import 'package:clawzilla/core/utils/system_prompt.dart';
import 'package:clawzilla/core/utils/turn_builder.dart';
import 'package:clawzilla/data/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final registry = ToolRegistry()..registerTools();

  group('ToolRegistry.looksLikeToolJob', () {
    test('plain chat is not a tool job', () {
      for (final m in [
        'hello',
        'hi',
        'good morning',
        'what time is it',
        'how are you',
        "what's the capital of France",
        'tell me a joke',
        'explain quantum computing',
        'what does this word mean',
      ]) {
        expect(
          ToolRegistry.looksLikeToolJob(m),
          isFalse,
          reason: '"$m" must stay compact',
        );
      }
    });

    test('tool jobs are detected', () {
      const jobs = {
        'text Shannon good morning': 'send_sms',
        'send a message to mom': 'send_sms',
        'add a calendar event for Friday at 3': 'create_calendar_event',
        'set an alarm for 6am': 'set_alarm',
        'remind me to call dad': 'set_alarm',
        'generate a snow-globe city at dusk': 'generate_on_site',
        'draw me a picture of a dog': 'generate_on_site',
        'open youtube': 'open_app',
        'search the web for best priced gaming laptops': 'web_search',
        "what's the weather": 'get_location',
        'where am i': 'get_location',
        'save a note about the gig': 'create_note',
        'add a task to buy milk': 'create_task',
        'list my goals': 'list_goals',
        'save this code to the project': 'write_project_file',
      };
      for (final entry in jobs.entries) {
        expect(
          ToolRegistry.looksLikeToolJob(entry.key),
          isTrue,
          reason: '"${entry.key}" (${entry.value}) must get the full section',
        );
      }
    });

    test('a bare "yes" counts when the prior message was a tool job', () {
      expect(
        ToolRegistry.looksLikeToolJob(
          'yes',
          priorUserMessages: ['generate a snow-globe city at dusk'],
        ),
        isTrue,
        reason: 'the #124 generate_on_site retry',
      );
      expect(
        ToolRegistry.looksLikeToolJob('yes'),
        isFalse,
        reason: 'a bare "yes" with no tool context stays compact',
      );
    });

    test('code and plan modes are tool jobs, images too', () {
      expect(
        ToolRegistry.looksLikeToolJob('hello', mode: 'code'),
        isTrue,
      );
      expect(
        ToolRegistry.looksLikeToolJob('hello', mode: 'plan'),
        isTrue,
      );
      expect(
        ToolRegistry.looksLikeToolJob('what is this?', hasImages: true),
        isTrue,
      );
      expect(
        ToolRegistry.looksLikeToolJob('hello', mode: 'chat'),
        isFalse,
      );
    });

    test('word boundaries: art does not fire on part or start', () {
      expect(ToolRegistry.looksLikeToolJob('this is part of it'), isFalse);
      expect(ToolRegistry.looksLikeToolJob('let us start'), isFalse);
      expect(ToolRegistry.looksLikeToolJob('show me some art'), isTrue);
    });
  });

  group('ToolRegistry.promptSection compact', () {
    test('names every tool, describes none of them', () async {
      final compact = await registry.promptSection(compact: true);
      for (final name in registry.toolsForModel.map((t) => t.name)) {
        expect(compact, contains(name));
      }
      // No descriptions: the long generate_on_site and file-tool
      // descriptions must not survive the cut.
      expect(compact, isNot(contains('Send an SMS to a phone number')));
      expect(
        compact,
        isNot(contains('Generate an image on Artistly')),
      );
      expect(compact, isNot(contains('Only use when the user asked')));
      // The format and the escape hatch stay: the model still knows how
      // to call a tool and when not to.
      expect(compact, contains('```json'));
      expect(compact, contains('open_app'));
      expect(
        compact,
        contains('If no tool fits the request, answer directly'),
      );
      // And the short file-save rule stays, so code written on a plain
      // chat turn still lands in Projects.
      expect(compact, contains('save it with write_project_file'));
    });

    test('a Blocked tool is hidden from the compact section too', () async {
      final compact = await registry.promptSection(
        compact: true,
        blockedTools: {'generate_on_site'},
      );
      expect(compact, isNot(contains('generate_on_site')));
    });

    test('the full section is unchanged (default)', () async {
      final full = await registry.promptSection();
      expect(full, contains('- send_sms: Send an SMS to a phone number'));
      expect(full, contains('Generate an image on Artistly'));
      expect(full, contains('save it with write_project_file'));
    });

    test('the cut is measured: compact under 250 tokens, saving over 700',
        () async {
      final full = await registry.promptSection();
      final compact = await registry.promptSection(compact: true);
      final fullTokens = estimateTokens(full);
      final compactTokens = estimateTokens(compact);
      // The full section is ~990 tokens by this same estimator; if the
      // tool list grows, the saving only grows with it.
      expect(fullTokens, greaterThan(800));
      expect(compactTokens, lessThan(250));
      expect(fullTokens - compactTokens, greaterThan(700));
    });
  });

  group('system prompt with the compact section', () {
    test('a plain hello assembles to a short prompt', () {
      // Representative parts for a fresh normal-mode hello: the real
      // skills section is ~1255 chars; the memories section is empty
      // here, as on Aaron's phone (the measured 1,393-token prompt is
      // accounted for without it).
      final prompt = buildSystemPrompt(
        nowLine: 'Today is Saturday, November 21, 2026. '
            'The current time is 4:08 AM.',
        locationLine: 'LOCATION: Home office, Austin, Texas.',
        personality:
            "You are Cypher, Aaron's personal AI assistant. Be concise and accurate.",
        coreSkillsSection:
            'Core skills — how to work:\n${'x' * 1229}',
        toolsSection: 'Tools: send_sms, open_app',
      );
      // The tools section is the variable under test; with the compact
      // form the whole system prompt stays well under the ~1,400 tokens
      // a full-section prompt costs. At ~11.6 tok/s that is the
      // difference between a ~50s prefill and a ~125s one.
      expect(prompt, isNotNull);
      expect(estimateTokens(prompt!), lessThan(700));
    });
  });
}
