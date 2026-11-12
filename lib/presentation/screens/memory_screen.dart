/// Memory screen for RAG and stored memories.
///
/// The search field is pinned rather than hidden behind the app-bar icon. A
/// memory list is browsed and filtered in the same breath — "did it remember
/// X?" — and making that two taps plus a dialog turn the most common question
/// about this screen into the most expensive one.
///
/// The list is real now: memories live in [MemoryStore] (the phone's
/// database, `user_memories` key), most recent first, and start empty.
/// What this screen used to show was three hardcoded demo entries whose
/// Save and Delete buttons wrote nowhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../data/services/memory_store.dart';
import '../widgets/screen_empty_state.dart';

/// The accent colour and glyph for each memory type.
///
/// The colour is what distinguishes a card at a glance in a list, so the map
/// lives in one place rather than being re-derived in the card, the badge and
/// the accent bar.
///
/// Not `const`: `brand` stopped being a constant when the theme-colour
/// setting landed (build #85) — it is set from the setting before the theme
/// is built, so a const map naming it cannot compile.
final Map<String, Color> _typeAccent = {
  'preference': AppColors.brand,
  'conversation': AppColors.accent,
  'profile': AppColors.success,
};

/// The types a memory can be. The order is the order the chips show.
const List<String> _memoryTypes = ['preference', 'conversation', 'profile'];

Color _accentFor(String? type) => _typeAccent[type] ?? AppColors.accent;

IconData _iconForType(String? type) {
  switch (type) {
    case 'preference':
      return Icons.favorite_outline;
    case 'conversation':
      return Icons.chat_bubble_outline;
    case 'profile':
      return Icons.person_outline;
    default:
      return Icons.memory;
  }
}

class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      body: const MemoryList(),
    );
  }
}

/// List of stored memories, read from [MemoryStore].
class MemoryList extends ConsumerStatefulWidget {
  const MemoryList({super.key});

  @override
  ConsumerState<MemoryList> createState() => _MemoryListState();
}

class _MemoryListState extends ConsumerState<MemoryList> {
  List<Map<String, dynamic>> _memories = [];
  String _query = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await MemoryStore.instance.entries();
    if (!mounted) return;
    setState(() {
      _memories = all;
      _loaded = true;
    });
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _memories;
    return _memories
        .where(
          (m) => (m['content'] as String).toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final memories = _filtered;
    return Column(
      children: [
        _SearchField(
          onQueryChanged: (q) => setState(() => _query = q),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a memory'),
              onPressed: () => _editMemory(context, null),
            ),
          ),
        ),
        Expanded(
          child: !_loaded
              ? const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : memories.isEmpty
                  ? const ScreenEmptyState(
                      icon: Icons.memory,
                      title: 'Nothing remembered yet',
                      message:
                          'Conversations, notes and anything the agent learns are '
                          'stored here so it can bring them up later.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      itemCount: memories.length,
                      itemBuilder: (context, index) {
                        final memory = memories[index];
                        return FadeSlideIn(
                          delay: staggerDelay(index),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: MemoryCard(
                              memory: memory,
                              onDelete: () =>
                                  _deleteMemory(context, memory),
                              onEdit: () => _editMemory(context, memory),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  void _deleteMemory(
    BuildContext context,
    Map<String, dynamic> memory,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Memory'),
        content: const Text('Are you sure you want to delete this memory?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await MemoryStore.instance
                  .remove(memory['id'] as String);
              if (context.mounted) Navigator.pop(context);
              _load();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _editMemory(
    BuildContext context,
    Map<String, dynamic>? memory,
  ) {
    showDialog(
      context: context,
      builder: (context) => MemoryEditDialog(
        memory: memory,
        onSaved: (content, type) async {
          if (memory == null) {
            await MemoryStore.instance.add(content, type);
          } else {
            await MemoryStore.instance.update(
              memory['id'] as String,
              content,
              type,
            );
          }
          _load();
        },
      ),
    );
  }
}

/// The pinned search field.
///
/// A real filter over the visible list rather than a dialog that closes on
/// submit: the result should update while typing, because the user is
/// recalling something, not issuing a query.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.onQueryChanged});

  final ValueChanged<String> onQueryChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _controller,
        style: Theme.of(context).textTheme.bodyMedium,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search memories',
          prefixIcon: Icon(Icons.search, size: 20, color: scheme.primary),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _controller.clear();
                    widget.onQueryChanged('');
                    setState(() {});
                  },
                ),
          isDense: true,
        ),
        onChanged: (v) {
          widget.onQueryChanged(v);
          setState(() {});
        },
      ),
    );
  }
}

/// Memory card widget
class MemoryCard extends StatelessWidget {
  final Map<String, dynamic> memory;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const MemoryCard({
    super.key,
    required this.memory,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = memory['type'] as String?;
    final tint = _accentFor(type);
    final radius = BorderRadius.circular(AppTheme.radiusLarge);

    return Dismissible(
      key: Key(memory['id'] as String),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.18),
          borderRadius: radius,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Delete',
              style: TextStyle(color: AppColors.danger, fontSize: 13),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete_outline, color: AppColors.danger),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: AppColors.surface,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The accent bar is what makes a scrolled list of otherwise
                // identical cards scannable: the type is legible from the
                // left edge alone, without reading any text.
                Container(width: 3, color: tint),
                Expanded(
                  child: ListTile(
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: tint.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(_iconForType(type), color: tint, size: 18),
                    ),
                    title: Text(
                      memory['content'] as String,
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          _TypeBadge(label: type ?? 'memory', tint: tint),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _formatTimestamp(memory['timestamp'] as int),
                              style: theme.textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit',
                      onPressed: onEdit,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// The type word, spelled out. "Preference" is clearer than an icon alone.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.tint});

  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tint),
      ),
    );
  }
}

/// Memory add/edit dialog.
///
/// A null [memory] means add; a set one means edit. Save writes through
/// [onSaved] (the list reloads from the store), so the edit actually
/// sticks — the old dialog just closed and threw the text away.
class MemoryEditDialog extends StatefulWidget {
  final Map<String, dynamic>? memory;
  final Future<void> Function(String content, String type) onSaved;

  const MemoryEditDialog({
    super.key,
    this.memory,
    required this.onSaved,
  });

  @override
  State<MemoryEditDialog> createState() => _MemoryEditDialogState();
}

class _MemoryEditDialogState extends State<MemoryEditDialog> {
  late TextEditingController _controller;
  late String _type;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.memory?['content'] as String? ?? '',
    );
    final savedType = widget.memory?['type'] as String?;
    _type = _memoryTypes.contains(savedType) ? savedType! : 'preference';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdd = widget.memory == null;
    return AlertDialog(
      title: Text(isAdd ? 'Add a memory' : 'Edit Memory'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: isAdd,
            decoration: const InputDecoration(
              hintText: 'Edit memory content...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final t in _memoryTypes)
                ChoiceChip(
                  label: Text(t),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            await widget.onSaved(text, _type);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
