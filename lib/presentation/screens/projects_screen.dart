/// Projects — the IDE's file list.
///
/// Shows every file under the projects folder picked in Settings, most
/// recently changed first. Tapping a text file opens it in the editor;
/// files over 1 MB are refused with a message rather than loaded into
/// memory. When no folder is picked, the screen offers the picker inline
/// instead of sending the user to Settings.
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final folder =
        ref.read(settingsProvider)['projects_folder'] as String?;
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
