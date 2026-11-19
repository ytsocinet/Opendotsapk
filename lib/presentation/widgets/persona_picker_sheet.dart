/// Persona picker sheet (build #122, Personas Piece B).
///
/// The bottom sheet the header chip opens: one persona active at a time,
/// globally (plan §3 — no multi-select stack, no per-chat persona). A tap
/// writes the persona's id to the `active_persona_id` setting and closes
/// the sheet; the prompt text follows from
/// [activePersonaPromptProvider], so both local and cloud turns pick it
/// up from the one assembly point in `ChatScreenState._buildRequest`.
///
/// Pumped directly in `test/persona_ui_test.dart` — it never touches a
/// real database (the list comes from `personasProvider`, the setting
/// from `settingsProvider`, both overridden in tests).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/personas_provider.dart';
import '../providers/providers.dart';

/// Open the picker as a modal bottom sheet. Used by [PersonaChip] in
/// `chat_screen.dart`; the sheet itself is [PersonaPickerSheet] so tests
/// can pump it without going through the chip.
Future<void> showPersonaPickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => const PersonaPickerSheet(),
  );
}

class PersonaPickerSheet extends ConsumerWidget {
  const PersonaPickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(personasProvider);
    final activeId =
        ref.watch(settingsProvider)['active_persona_id'] as String?;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle, same shape as the app's other bottom sheets.
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Switch persona',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          if (personas.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: personas.length,
                itemBuilder: (context, index) {
                  final persona = personas[index];
                  final active = persona.id == activeId;
                  return ListTile(
                    leading: Text(
                      persona.emoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(persona.name),
                    subtitle: persona.description != null
                        ? Text(
                            persona.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: active
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    onTap: () async {
                      // State updates first inside updateSetting, so the
                      // chip already shows the new persona by the time
                      // the sheet slides away.
                      await ref
                          .read(settingsProvider.notifier)
                          .updateSetting('active_persona_id', persona.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
