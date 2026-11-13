/// Projects — the IDE's file list.
///
/// Shows every file under the projects folder picked in Settings, most
/// recently changed first. Tapping a text file opens it in the editor;
/// files over 1 MB are refused with a message rather than loaded into
/// memory. When no folder is picked, the screen offers the picker inline
/// instead of sending the user to Settings. The + button creates a new
/// empty file in the folder and opens it in the editor.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/log.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';
import 'code_editor_screen.dart';

/// Files over this size are not opened in the editor.
const int _maxEditableBytes = 1024 * 1024;

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  List<File> _files = [];
  bool _loading = true;
  String? _error;
  // The folder value _reload() last loaded for. The screen only loads
  // its list once in initState, but the folder can be picked later in
  // Settings (or removed there); the listener in build compares the
  // current setting against this and reloads when it changes.
  String? _loadedFolder;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final folder =
        ref.read(settingsProvider)['projects_folder'] as String?;
    // Record this synchronously, before any await, so a second change
    // while a listing is in flight cannot trigger a duplicate reload.
    _loadedFolder = folder;
    if (folder == null || folder.isEmpty) {
      if (mounted) {
        setState(() {
          _files = [];
          _loading = false;
          _error = null;
        });
      }
      return;
    }
    try {
      final dir = Directory(folder);
      if (!await dir.exists()) {
        if (mounted) {
          setState(() {
            _files = [];
            _loading = false;
            _error = 'That folder no longer exists — pick another one.';
          });
        }
        return;
      }
      final found = <File>[];
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) found.add(entity);
      }
      // Most recently changed first, so the file being worked on is at
      // the top rather than buried under an alphabetical listing.
      found.sort(
        (a, b) => b
            .statSync()
            .modified
            .compareTo(a.statSync().modified),
      );
      if (mounted) {
        setState(() {
          _files = found;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      Log.w('projects list failed: $e');
      if (mounted) {
        setState(() {
          _files = [];
          _loading = false;
          _error = 'Could not list that folder: $e';
        });
      }
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Pick your projects folder',
    );
    if (path == null) return;
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('projects_folder', path);
    setState(() => _loading = true);
    await _reload();
  }

  Future<void> _open(File file) async {
    final size = await file.length();
    if (size > _maxEditableBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That file is over 1 MB — too big to edit here.'),
        ),
      );
      return;
    }
    // Remember this file so the IDE drawer tile can reopen it directly.
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('last_ide_file', file.path);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CodeEditorScreen(path: file.path),
      ),
    );
    // The file may have changed while the editor was open.
    await _reload();
  }

  /// Create a new empty file in the projects folder and open it.
  ///
  /// The name is a bare file name, not a path: slashes and ".." are
  /// refused, and an existing file is never overwritten. The file is
  /// opened through [_open] so the IDE tile remembers it.
  Future<void> _createFile() async {
    final folder = ref.read(settingsProvider)['projects_folder'] as String?;
    if (folder == null || folder.isEmpty) return;
    final controller = TextEditingController();
    String? error;

    // Validates the typed name inside the dialog, showing the problem
    // there; returns the name to the caller only when it is usable.
    Future<void> submit(StateSetter setDialogState) async {
      final name = controller.text.trim();
      if (name.isEmpty) {
        setDialogState(() => error = 'Give the file a name.');
        return;
      }
      if (name.contains('/') ||
          name.contains(r'\') ||
          name.contains('..')) {
        setDialogState(
          () => error = 'That is not a file name — no / , \\ or ..',
        );
        return;
      }
      if (await File(p.join(folder, name)).exists()) {
        setDialogState(
          () => error = 'A file with that name already exists.',
        );
        return;
      }
      if (mounted) Navigator.pop(context, name);
    }

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('New file'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'e.g. notes.txt',
              errorText: error,
            ),
            onSubmitted: (_) => submit(setDialogState),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => submit(setDialogState),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (name == null) return;
    try {
      final file = File(p.join(folder, name));
      await file.create();
      await _open(file);
    } catch (e) {
      Log.w('create file failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create that file: $e')),
      );
    }
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder =
        ref.watch(settingsProvider)['projects_folder'] as String?;
    final folderSet = folder != null && folder.isNotEmpty;

    // The folder can change outside this screen (picked in Settings, or
    // removed there). All tabs stay mounted, so initState's one reload
    // is not enough: reload whenever the setting moves. The listener
    // fires after the provider changes, never during build, and
    // _reload() guards its own setState with mounted. A pick made from
    // this screen's own button also reloads directly in _pickFolder;
    // the _loadedFolder guard keeps that from doubling the work.
    ref.listen(
      settingsProvider.select((s) => s['projects_folder'] as String?),
      (previous, next) {
        if (next != _loadedFolder) _reload();
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        actions: [
          if (folderSet)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh list',
              onPressed: _reload,
            ),
        ],
      ),
      floatingActionButton: folderSet
          ? FloatingActionButton(
              onPressed: _createFile,
              tooltip: 'New file',
              child: const Icon(Icons.add),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !folderSet
              ? ScreenEmptyState(
                  icon: Icons.folder_outlined,
                  title: 'No projects folder yet',
                  message: 'Point Cypher at a folder and it will list '
                      'the files inside — you and Cypher can both edit '
                      'them from here.',
                  actionLabel: 'Pick a folder',
                  onAction: _pickFolder,
                )
              : _error != null
                  ? ScreenEmptyState(
                      icon: Icons.folder_off_outlined,
                      title: 'Folder unavailable',
                      message: _error!,
                      actionLabel: 'Pick another folder',
                      onAction: _pickFolder,
                    )
                  : _files.isEmpty
                      ? ScreenEmptyState(
                          icon: Icons.folder_open,
                          title: 'Folder is empty',
                          message: 'Nothing in $folder yet.',
                          actionLabel: 'Pick another folder',
                          onAction: _pickFolder,
                        )
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                8,
                                16,
                                4,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      folder,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _pickFolder,
                                    child: const Text('Change'),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 4, 16, 32),
                                itemCount: _files.length,
                                itemBuilder: (context, i) {
                                  final file = _files[i];
                                  final size = file.statSync().size;
                                  return Card(
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.description_outlined,
                                      ),
                                      title: Text(
                                        p.relative(file.path, from: folder),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        _sizeLabel(size),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      onTap: () => _open(file),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
    );
  }
}
