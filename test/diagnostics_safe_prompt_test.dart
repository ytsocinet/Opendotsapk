/// Build #98: the diagnostic safe prompt strips exactly the saved
/// memories, the core skills, and the tools section — and nothing else.
///
/// The assembly is pure string work in `buildSystemPrompt`, extracted from
/// `ChatScreenState._buildRequest` so it can be pinned here without
/// pumping the whole chat screen. The chat screen passes `safePrompt`
/// from the `diagnostic_safe_prompt` setting on local turns only; the
/// cloud path never passes it, so cloud turns are unchanged.
library;

import 'package:clawzilla/core/utils/system_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildSystemPrompt', () {
    const now =
        'Today is Saturday, November 15, 2026. The current time is 12:00 AM.';
    const location = 'LOCATION: Indianapolis, IN — 45°F, clear.';
    const personality = 'professional';
    const mode = 'Answer briefly.';
    const memories =
        'Things to remember about the user:\n- [preference] likes drill';
    const skills =
        'Core skills — how to work:\n- Ponytail: do not over-engineer.';
    const tools = 'You can use tools.\nTools:\n- open_app: open an app';

    String prompt({bool safePrompt = false}) => buildSystemPrompt(
          nowLine: now,
          locationLine: location,
          personality: personality,
          modeInstruction: mode,
          memoriesSection: memories,
          coreSkillsSection: skills,
          toolsSection: tools,
          safePrompt: safePrompt,
        )!;

    test('off: includes memories, skills, and tools, in that order', () {
      final p = prompt();
      expect(p, contains(now));
      expect(p, contains(location));
      expect(p, contains(personality));
      expect(p, contains(mode));
      expect(p, contains(memories));
      expect(p, contains(skills));
      expect(p, contains(tools));
      expect(p.indexOf(memories), lessThan(p.indexOf(skills)));
      expect(p.indexOf(skills), lessThan(p.indexOf(tools)));
    });

    test('safe mode on: drops memories, skills, and tools, keeps the rest',
        () {
      final p = prompt(safePrompt: true);
      expect(p, contains(now));
      expect(p, contains(location));
      expect(p, contains(personality));
      expect(p, contains(mode));
      expect(p, isNot(contains(memories)));
      expect(p, isNot(contains(skills)));
      expect(p, isNot(contains(tools)));
      expect(p, isNot(contains('Things to remember')));
      expect(p, isNot(contains('Core skills')));
      expect(p, isNot(contains('You can use tools')));
    });

    test('safe mode off is the default', () {
      // No safePrompt argument: identical to off.
      final p = buildSystemPrompt(
        nowLine: now,
        memoriesSection: memories,
      )!;
      expect(p, contains(memories));
      expect(p, contains(now));
    });

    test('location unknown line is kept in safe mode', () {
      final p = buildSystemPrompt(
        nowLine: now,
        safePrompt: true,
      )!;
      expect(p, contains(now));
      expect(p, contains('LOCATION: unknown'));
    });

    test('safe mode with everything stripped still keeps date/time', () {
      final p = buildSystemPrompt(
        nowLine: now,
        locationLine: location,
        personality: personality,
        modeInstruction: mode,
        memoriesSection: memories,
        coreSkillsSection: skills,
        toolsSection: tools,
        safePrompt: true,
      )!;
      expect(p, contains(now));
      expect(p, contains(location));
      expect(p, contains(personality));
      expect(p, contains(mode));
    });

    test('a blank tools section is never included', () {
      final p = buildSystemPrompt(
        nowLine: now,
        locationLine: location,
        toolsSection: '   ',
      )!;
      expect(p, isNot(contains('   ')));
      expect(p, '$now\n\n$location');
    });
  });
}
