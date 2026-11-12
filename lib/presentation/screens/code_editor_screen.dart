/// Code editor — one text file, editable, saved back in place.
///
/// v1 is a plain editor: the file's text in a full-screen field, Save
/// writes it back to the same path. No syntax highlighting, no running
/// code — that is a later step. Files over 1 MB are refused at the
/// Projects screen, so this screen never has to hold a huge file.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class CodeEditorScreen extends StatefulWidget {
  const CodeEditorScreen({super.key, required this.path});

  /// Absolute path of the file being edited.
  final String path;

  @override
  State<CodeEditorScreen> createState() => _CodeEditorScreenState();
}

class _CodeEditorScreenState extends State<CodeEditorScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = true;
  bool _dirty = false;
  bool _allowPop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    try {
      final text = await File(widget.path).readAsString();
      if (!mounted) return;
      setState(() {
        // Set the text before attaching the listener, so loading the
        // file does not count as an edit.
        _controller.text = text;
        _loading = false;
      });
      _controller.addListener(_markDirty);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read that file: $e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    try {
      await File(widget.path).writeAsString(_controller.text);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved edits to this file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // Blocked until the user confirms discarding (or there is nothing
      // to discard). When a discard is confirmed [_allowPop] flips and
      // the pop is retried after the rebuild, so the veto does not eat
      // the confirmed pop.
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && mounted) {
          setState(() => _allowPop = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.pop(context);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            p.basename(widget.path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save',
              onPressed: _loading || _error != null ? null : _save,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Empty file — start typing.',
                      ),
                    ),
                  ),
      ),
    );
  }
}
