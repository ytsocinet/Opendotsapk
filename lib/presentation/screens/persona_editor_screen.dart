/// Persona editor (build #122, Personas Piece B).
///
/// Create a custom persona or edit one. A null [persona] means "new";
/// a built-in opens read-only — built-ins cannot be edited or deleted
/// in v1 (plan §3), so the fields are disabled, the Save action is
/// hidden, and a note says so. The read-only view still lets Aaron read
/// a built-in's full system prompt.
///
/// Fields (plan §4, Piece B): emoji from a fixed set, name ≤50 chars,
/// description ≤200 optional, system-prompt text area with a length
/// warning past ~1000 chars. No "Advanced settings": there are no
/// per-persona sampling params — Prompt Lab stays the single place for
/// temperature/topK/maxTokens, and there is no per-persona model either.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/models/persona.dart';
import '../providers/personas_provider.dart';

/// The fixed emoji set the picker offers (upstream's pattern: a small
/// grid of common emojis, not a full keyboard picker).
const List<String> personaEmojiOptions = [
  '🤖', '💻', '📚', '✍️', '🏋️', '🧠', '🎨', '🎵', '🍳', '✈️',
  '💼', '🗣️', '🔍', '🦸', '🧙', '🕵️', '🌟', '🔥', '💡', '📈',
  '❤️', '😄', '🐱', '🦊', '🚀', '🎯', '📖', '💬', '🧑‍🏫', '👩‍💻',
];

/// Past this many system-prompt characters the editor shows a length
/// warning: a very long prompt rides along on every turn and eats
/// context on a 3B local model. A warning, not a cap — long is allowed.
const int personaPromptLengthWarning = 1000;

class PersonaEditorScreen extends ConsumerStatefulWidget {
  const PersonaEditorScreen({super.key, this.persona});

  /// The persona being edited, or null to create a new custom one.
  final Persona? persona;

  @override
  ConsumerState<PersonaEditorScreen> createState() =>
      _PersonaEditorScreenState();
}

class _PersonaEditorScreenState extends ConsumerState<PersonaEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _promptController;
  late String _emoji;

  /// True when the opened persona is a built-in: everything is
  /// read-only and there is no Save action.
  bool get _readOnly => widget.persona?.isBuiltIn ?? false;

  @override
  void initState() {
    super.initState();
    final persona = widget.persona;
    _nameController = TextEditingController(text: persona?.name ?? '');
    _descriptionController = TextEditingController(
      text: persona?.description ?? '',
    );
    _promptController = TextEditingController(
      text: persona?.systemPrompt ?? '',
    );
    _emoji = persona?.emoji ?? personaEmojiOptions.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameController.text.trim();
    final prompt = _promptController.text.trim();
    final description = _descriptionController.text.trim();
    final notifier = ref.read(personasProvider.notifier);
    final existing = widget.persona;
    if (existing == null) {
      await notifier.createPersona(
        name: name,
        emoji: _emoji,
        systemPrompt: prompt,
        description: description.isEmpty ? null : description,
      );
    } else {
      // Built as a fresh Persona rather than copyWith: copyWith cannot
      // clear the description (a null argument means "keep the old
      // one"), and clearing it is a legitimate edit.
      await notifier.updatePersona(
        Persona(
          id: existing.id,
          name: name,
          emoji: _emoji,
          systemPrompt: prompt,
          description: description.isEmpty ? null : description,
          isBuiltIn: false,
          createdAt: existing.createdAt,
          updatedAt: DateTime.now(),
        ),
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final persona = widget.persona;
    final promptLength = _promptController.text.length;
    final promptTooLong = promptLength > personaPromptLengthWarning;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          persona == null ? 'New persona' : persona.name,
        ),
        actions: [
          if (!_readOnly)
            TextButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          key: const Key('persona_editor_scroll'),
          padding: const EdgeInsets.all(16),
          children: [
            if (_readOnly)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outline),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Built-in personas can't be edited or deleted.",
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              'Emoji',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 6,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: personaEmojiOptions.length,
              itemBuilder: (context, index) {
                final emoji = personaEmojiOptions[index];
                final selected = emoji == _emoji;
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _readOnly
                      ? null
                      : () => setState(() => _emoji = emoji),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected
                            ? scheme.primary
                            : scheme.outline.withValues(alpha: 0.5),
                        width: selected ? 2 : 1,
                      ),
                      color: selected
                          ? scheme.primary.withValues(alpha: 0.12)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      emoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('persona_name_field'),
              controller: _nameController,
              enabled: !_readOnly,
              autofocus: persona == null,
              maxLength: 50,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Coach',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Give the persona a name.';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('persona_description_field'),
              controller: _descriptionController,
              enabled: !_readOnly,
              maxLength: 200,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'One short line shown in the list',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('persona_prompt_field'),
              controller: _promptController,
              enabled: !_readOnly,
              minLines: 5,
              maxLines: 10,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'System prompt',
                hintText:
                    'e.g. You are a patient tutor. Explain step by step…',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'The system prompt is what the persona does — it can’t be empty.';
                }
                return null;
              },
            ),
            const SizedBox(height: 4),
            Text(
              promptTooLong
                  ? 'Long prompt — $promptLength characters. It rides along on every turn, so very long prompts eat into the context a 3B local model can use.'
                  : '$promptLength characters',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: promptTooLong
                        ? AppColors.warning
                        : scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
