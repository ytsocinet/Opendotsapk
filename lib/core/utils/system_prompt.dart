/// Assembles the system prompt for a chat turn from its parts.
///
/// Extracted from `ChatScreenState._buildRequest` (build #98) so the
/// diagnostic safe-prompt mode can be tested without pumping the whole
/// chat screen: the assembly is pure string work, and the test pins that
/// safe mode drops exactly the three diagnostic sections and nothing else.
///
/// Part order is load-bearing — the model sees date/time first, then
/// location, personality, the mode instruction, saved memories, core
/// skills, and the tools section last. Do not reorder without updating
/// `test/diagnostics_safe_prompt_test.dart`.
library;

/// The system prompt is the date and time first — the model has no clock
/// of its own — then where the user is and the temperature, then the
/// personality plus the mode's instruction, when the mode has one, then
/// the user's saved memories and the core skills. Chat mode adds nothing.
/// The tools section goes last, and only on the local path: the cloud
/// path never parses tool calls, so a tools section there would only make
/// the model print raw JSON.
///
/// When [safePrompt] is on, the saved memories, the core skills, and the
/// tools section are left out — those are the three sections that grew
/// the prompt in builds #89/#91/#94/#95, and dropping them tests whether
/// the prompt is what kills a local turn. Everything else (date/time,
/// location, personality, mode instruction) is kept. Safe mode is
/// local-only: the cloud path never passes `safePrompt: true`, so cloud
/// turns are unchanged. When off, the result is byte-identical to the
/// inline assembly this replaces.
String? buildSystemPrompt({
  required String nowLine,
  String? locationLine,
  String? personality,
  String? modeInstruction,
  String? memoriesSection,
  String? coreSkillsSection,
  String? toolsSection,
  bool safePrompt = false,
}) {
  final systemParts = <String>[
    nowLine,
    if (locationLine != null) locationLine,
    // When the location line is missing, say so outright. A small model
    // asked "where am I?" with no location in the prompt used to answer
    // with the time from the line above — or invent a temperature. An
    // honest "unknown" beats a confident wrong answer.
    if (locationLine == null)
      'LOCATION: unknown — if asked where the user is or what the '
      'temperature is, say you do not know; do not guess.',
    if (personality != null && personality.trim().isNotEmpty) personality,
    if (modeInstruction != null) modeInstruction,
    if (!safePrompt && memoriesSection != null) memoriesSection,
    if (!safePrompt && coreSkillsSection != null) coreSkillsSection,
    if (!safePrompt &&
        toolsSection != null &&
        toolsSection.trim().isNotEmpty)
      toolsSection,
  ];
  return systemParts.isEmpty ? null : systemParts.join('\n\n');
}
