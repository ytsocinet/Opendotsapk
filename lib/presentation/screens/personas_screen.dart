/// Personas list (build #122, Personas Piece B).
///
/// The drawer opens this screen. One row per persona: emoji, name,
/// description, and a "Built-in" label on the four that ship with the
/// app. Tap a row to edit it (built-ins open read-only — see
/// [PersonaEditorScreen]); customs also get a delete button and a
/// long-press delete, both behind a confirm dialog. The "+" button
/// creates a new custom persona.
///
/// Deleting the active persona resets the active id to Cypher first,
/// so the header chip never points at a persona that is gone — the
/// prompt fallback in `PersonasNotifier.resolveActivePrompt` would
/// cover it anyway, but the setting should say what is actually
/// active.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/motion.dart';
import '../../domain/models/persona.dart';
import '../providers/personas_provider.dart';
import '../providers/providers.dart';
import 'persona_editor_screen.dart';

class PersonasScreen extends ConsumerWidget {
  const PersonasScreen({super.key});

  void _openEditor(BuildContext context, Persona? persona) {
    Navigator.of(context).push(
      AppPageRoute(builder: (_) => PersonaEditorScreen(persona: persona)),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Persona persona,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete persona?'),
        content: Text(
          '"${persona.name}" will be deleted. This can’t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Deleting the active persona first hands the active slot back to
    // Cypher, so no setting ever names a deleted persona.
    final activeId =
        ref.read(settingsProvider)['active_persona_id'] as String?;
    if (activeId == persona.id) {
      await ref
          .read(settingsProvider.notifier)
          .updateSetting(
            'active_persona_id',
            PersonasNotifier.defaultPersonaId,
          );
    }
    await ref.read(personasProvider.notifier).deletePersona(persona.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(personasProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Personas')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(context, null),
        tooltip: 'New persona',
        child: const Icon(Icons.add),
      ),
      body: personas.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: personas.length,
              itemBuilder: (context, index) {
                final persona = personas[index];
                return ListTile(
                  leading: Text(
                    persona.emoji,
                    style: const TextStyle(fontSize: 28),
                  ),
                  title: Text(persona.name),
                  subtitle: persona.description != null
                      ? Text(persona.description!)
                      : null,
                  trailing: persona.isBuiltIn
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outline),
                          ),
                          child: Text(
                            'Built-in',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete ${persona.name}',
                          onPressed: () =>
                              _confirmDelete(context, ref, persona),
                        ),
                  onTap: () => _openEditor(context, persona),
                  onLongPress: persona.isBuiltIn
                      ? null
                      : () => _confirmDelete(context, ref, persona),
                );
              },
            ),
    );
  }
}
