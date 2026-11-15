/// Diagnostics screen (build #98): the crash log, and the minimal-prompt
/// safe mode used to test whether the prompt is what kills a local turn.
///
/// The crash log is the file `crash.log` in the app documents directory,
/// written by main.dart: uncaught Dart errors are appended synchronously
/// (`FlutterError.onError` and the `runZonedGuarded` handler), so the
/// record lands even if the isolate dies right after. A native crash
/// writes nothing — an empty or missing log after a crash is itself
/// evidence that the fault is below Dart, in the native engine.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';
import '../widgets/screen_section_card.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() =>
      _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  bool _loading = true;
  String? _error;
  bool _exists = false;
  String? _contents;
  int _bytes = 0;
  DateTime? _modified;

  @override
  void initState() {
    super.initState();
    _loadLog();
  }

  Future<File> _crashLogFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/crash.log');
  }

  Future<void> _loadLog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await _crashLogFile();
      if (!await file.exists()) {
        if (mounted) {
          setState(() {
            _loading = false;
            _exists = false;
            _contents = null;
            _bytes = 0;
            _modified = null;
          });
        }
        return;
      }
      final stat = await file.stat();
      final contents = await file.readAsString();
      if (mounted) {
        setState(() {
          _loading = false;
          _exists = true;
          _contents = contents;
          _bytes = stat.size;
          _modified = stat.modified;
        });
      }
    } catch (e) {
      // A log that cannot be read is reported, not swallowed: the point
      // of this screen is evidence, and a failed read is evidence too.
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not read the crash log: $e';
        });
      }
    }
  }

  Future<void> _clearLog() async {
    try {
      final file = await _crashLogFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear the crash log: $e')),
        );
      }
      return;
    }
    await _loadLog();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crash log cleared')),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} '
        '$hour12:$minute $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final safePrompt = settings['diagnostic_safe_prompt'] as bool? ?? false;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          ScreenSection(
            title: 'Safe prompt',
            subtitle: 'Send local turns with a minimal prompt.',
            child: SwitchListTile(
              secondary: ScreenRowIcon(
                icon: Icons.shield_outlined,
                color: safePrompt
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              title: const Text('Safe prompt (diagnostic)'),
              subtitle: const Text(
                'Local turns skip the saved memories, the core skills, '
                'and the tools section. Use it to test whether the prompt '
                'is what crashes a reply. Cloud turns are unchanged.',
              ),
              value: safePrompt,
              onChanged: (value) {
                ref
                    .read(settingsProvider.notifier)
                    .updateSetting('diagnostic_safe_prompt', value);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      value
                          ? 'Safe prompt on — local turns use a minimal prompt'
                          : 'Safe prompt off — local turns use the full prompt',
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          ScreenSection(
            title: 'Crash log',
            subtitle: 'Uncaught errors, as the app recorded them.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.error,
                    ),
                  )
                else if (!_exists)
                  const ScreenEmptyState(
                    icon: Icons.bug_report_outlined,
                    title: 'No crash log yet',
                    message:
                        'The log is written when the app catches an error. '
                        'Open this screen again after a crash.',
                    compact: true,
                  )
                else ...[
                  Text(
                    '${_formatBytes(_bytes)}'
                    '${_modified != null ? ' · modified ${_formatDate(_modified!)}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                        onPressed: _contents == null
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _contents!),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text('Crash log copied'),
                                    ),
                                  );
                                }
                              },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Share'),
                        onPressed: _contents == null
                            ? null
                            : () => Share.share(
                                _contents!,
                                subject: 'Clawzilla crash log',
                              ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Refresh'),
                        onPressed: _loadLog,
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text('Clear'),
                        onPressed: _clearLog,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_contents != null && _contents!.isEmpty)
                    Text(
                      'The crash log is empty. An empty log after a crash '
                      'means the crash happened below the app, in the '
                      'native engine — which is itself evidence: the Dart '
                      'side never saw an error.',
                      style: theme.textTheme.bodyMedium,
                    )
                  else if (_contents != null)
                    SelectableText(
                      _contents!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
