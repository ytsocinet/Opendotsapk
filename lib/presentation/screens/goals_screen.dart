/// Goals — longer-term aims with a note each, stored in the phone's
/// database.
///
/// A goal is a title plus free-form notes (what "done" looks like, the
/// next step, whatever matters). Tap a goal to edit it, tick it off when
/// it is finished. Like Tasks, v1 is manual — the agent does not add
/// goals yet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database_helper.dart';
import '../widgets/screen_empty_state.dart';

class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  List<Map<String, dynamic>> _goals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final goals = await DatabaseHelper.instance.getGoals();
    if (!mounted) return;
    setState(() {
      _goals = goals;
      _loading = false;
    });
  }

  Future<void> _editGoal({Map<String, dynamic>? existing}) async {
    final titleController =
        TextEditingController(text: '${existing?['title'] ?? ''}');
    final notesController =
        TextEditingController(text: '${existing?['notes'] ?? ''}');
    final result = await showDialog<({String title, String notes})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'New goal' : 'Edit goal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Goal'),
              onSubmitted: (_) => Navigator.pop(
                context,
                (
                  title: titleController.text.trim(),
                  notes: notesController.text.trim(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesController,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Notes — what does done look like?',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              (
                title: titleController.text.trim(),
                notes: notesController.text.trim(),
              ),
            ),
            child: Text(existing == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
    if (result == null || result.title.isEmpty) return;
    if (existing == null) {
      await DatabaseHelper.instance.insertGoal(
        id: const Uuid().v4(),
        title: result.title,
        notes: result.notes,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      await DatabaseHelper.instance.updateGoal(
        id: '${existing['id']}',
        title: result.title,
        notes: result.notes,
      );
    }
    await _reload();
  }

  Future<void> _toggle(String id, bool done) async {
    await DatabaseHelper.instance.updateGoal(id: id, done: !done);
    await _reload();
  }

  Future<void> _delete(String id) async {
    await DatabaseHelper.instance.deleteGoal(id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Goals'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _goals.isEmpty
              ? ScreenEmptyState(
                  icon: Icons.flag_outlined,
                  title: 'No goals yet',
                  message: 'Add one — a title and a note about what '
                      'done looks like.',
                  actionLabel: 'Add a goal',
                  onAction: () => _editGoal(),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: _goals.length,
                  itemBuilder: (context, i) {
                    final goal = _goals[i];
                    final done = (goal['done'] as int? ?? 0) == 1;
                    final notes = '${goal['notes'] ?? ''}';
                    return Card(
                      child: ListTile(
                        leading: Checkbox(
                          value: done,
                          onChanged: (_) => _toggle('${goal['id']}', done),
                        ),
                        title: Text(
                          '${goal['title'] ?? ''}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                            color: done ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                        subtitle: notes.isEmpty
                            ? null
                            : Text(
                                notes,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete goal',
                          onPressed: () => _delete('${goal['id']}'),
                        ),
                        onTap: () => _editGoal(existing: goal),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editGoal(),
        tooltip: 'Add a goal',
        child: const Icon(Icons.add),
      ),
    );
  }
}
