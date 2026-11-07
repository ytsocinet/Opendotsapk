/// The cold-start screen: what a user sees before their first message.
///
/// Deliberately sparse: a headline, one line of plain explanation, and —
/// when nothing is loaded — one large action. No emblem, no suggestion
/// chips. The old suggestion chips filled the composer with prompts the
/// user had not asked for, and the emblem was decoration competing with
/// the one thing that matters here: whether a model is loaded.
library;

import 'package:flutter/material.dart';

import '../../core/theme/motion.dart';

/// Designed empty state for the chat transcript.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.modelLoaded,
    required this.onManageModels,
  });

  /// Whether a model is actually bound to the runtime.
  final bool modelLoaded;

  /// Opens the Models screen.
  final VoidCallback onManageModels;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            FadeSlideIn(child: _Headline(modelLoaded: modelLoaded)),
            const SizedBox(height: 10),
            FadeSlideIn(
              delay: const Duration(milliseconds: 120),
              child: Text(
                modelLoaded
                    ? 'The model on this phone answers. Nothing you type '
                          'leaves it unless you choose the cloud.'
                    : 'Nothing is loaded yet, so there is nothing to talk to. '
                          'Pick a model first — it downloads once, then works '
                          'entirely offline.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (!modelLoaded) ...[
              const SizedBox(height: 28),
              FadeSlideIn(
                delay: const Duration(milliseconds: 180),
                child: FilledButton.icon(
                  onPressed: onManageModels,
                  icon: const Icon(Icons.download),
                  label: const Text('Choose a model'),
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideIn(
                delay: const Duration(milliseconds: 240),
                child: TextButton(
                  onPressed: onManageModels,
                  child: const Text('Open Models'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The headline line, plus the sub-line when there is no model.
class _Headline extends StatelessWidget {
  const _Headline({required this.modelLoaded});

  final bool modelLoaded;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          modelLoaded
              ? 'Ask anything — it never leaves your phone'
              : 'Download a model to start',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        if (!modelLoaded) ...[
          const SizedBox(height: 8),
          Text(
            'A few hundred megabytes to a few gigabytes, depending on the '
            'model you want.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
