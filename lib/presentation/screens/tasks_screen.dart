/// Tasks — a plain checklist, stored in the phone's database.
///
/// v1 is deliberately manual: add a task, tick it off, delete it. The
/// agent does not add tasks yet — that is a separate permission question,
/// not something to smuggle in with the list itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database_helper.dart';
import '../widgets/screen_empty_state.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  List<Map<String, dynamic>> _tasks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final tasks = await DatabaseHelper.instance.getTasks();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _loading = false;
    });
  }

  Future<void> _addTask() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New task'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'What needs doing?'),
          onSubmitted: (_) => Navigator.pop(context, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    await DatabaseHelper.instance.insertTask(
      id: const Uuid().v4(),
      title: title,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _reload();
  }

  Future<void> _toggle(String id, bool done) async {
    await DatabaseHelper.instance.setTaskDone(id: id, done: !done);
    await _reload();
  }

  Future<void> _delete(String id) async {
    await DatabaseHelper.instance.deleteTask(id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tasks.isEmpty
              ? ScreenEmptyState(
                  icon: Icons.checklist_outlined,
                  title: 'No tasks yet',
                  message: 'Add the first one — it will be here when '
                      'you come back.',
                  actionLabel: 'Add a task',
                  onAction: _addTask,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: _tasks.length,
                  itemBuilder: (context, i) {
                    final task = _tasks[i];
                    final done = (task['done'] as int? ?? 0) == 1;
                    return Card(
                      child: CheckboxListTile(
                        value: done,
                        onChanged: (_) => _toggle('${task['id']}', done),
                        title: Text(
                          '${task['title'] ?? ''}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                            color: done ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                        secondary: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete task',
                          onPressed: () => _delete('${task['id']}'),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addTask,
        tooltip: 'Add a task',
        child: const Icon(Icons.add),
      ),
    );
  }
}
