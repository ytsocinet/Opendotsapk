/// Diagnostics screen (build #98): the crash log, and the minimal-prompt
/// safe mode used to test whether the prompt is what kills a local turn.
/// Build #99 adds the native trace: `native_trace.log` in the same
/// directory, written by the native glue (via scripts/patch_native_llama.py)
/// at each generation stage — entered, template applied, tokenized N
/// tokens, each prefill chunk with its llama_decode return code, first
/// token, EOS — so a silent native failure (no token, no error, no crash)
/// is visible instead of surfacing only as a 90-second timeout.
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

  /// File name of the native generation trace in the app documents
  /// directory (build #99). Must match the path the native glue is told
  /// to write to (scripts/patch_native_llama.py sets
  /// "app_flutter/native_trace.log" from Kotlin): if the two disagree,
  /// the trace section silently shows "No native trace yet".
  static const String traceFileName = 'native_trace.log';

  /// The trace log file for a documents directory. Pure so it is
  /// unit-testable without pumping the screen.
  static File traceFile(Directory docs) =>
      File('${docs.path}/$traceFileName');

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

  // Native trace (build #99): same shape as the crash log above, one
  // section per file. Kept as parallel state rather than a shared widget
  // so the working crash-log section is untouched by this addition.
  bool _traceLoading = true;
  String? _traceError;
  bool _traceExists = false;
  String? _traceContents;
  int _traceBytes = 0;
  DateTime? _traceModified;

  @override
  void initState() {
    super.initState();
    _loadLog();
    _loadTraceLog();
  }

  Future<File> _crashLogFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/crash.log');
  }

  Future<File> _traceLogFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return DiagnosticsScreen.traceFile(docs);
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

  Future<void> _loadTraceLog() async {
    setState(() {
      _traceLoading = true;
      _traceError = null;
    });
    try {
      final file = await _traceLogFile();
      if (!await file.exists()) {
        if (mounted) {
          setState(() {
            _traceLoading = false;
            _traceExists = false;
            _traceContents = null;
            _traceBytes = 0;
            _traceModified = null;
          });
        }
        return;
      }
      final stat = await file.stat();
      final contents = await file.readAsString();
      if (mounted) {
        setState(() {
          _traceLoading = false;
          _traceExists = true;
          _traceContents = contents;
          _traceBytes = stat.size;
          _traceModified = stat.modified;
        });
      }
    } catch (e) {
      // A log that cannot be read is reported, not swallowed: the point
      // of this screen is evidence, and a failed read is evidence too.
      if (mounted) {
        setState(() {
          _traceLoading = false;
          _traceError = 'Could not read the native trace: $e';
        });
      }
    }
  }

  Future<void> _clearTraceLog() async {
    try {
      final file = await _traceLogFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear the native trace: $e')),
        );
      }
      return;
    }
    await _loadTraceLog();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Native trace cleared')),
      );
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
          const SizedBox(height: 24),
          ScreenSection(
            title: 'Native trace',
            subtitle:
                'Generation stages, as the native engine recorded them.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_traceLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_traceError != null)
                  Text(
                    _traceError!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.error,
                    ),
                  )
                else if (!_traceExists)
                  const ScreenEmptyState(
                    icon: Icons.timeline_outlined,
                    title: 'No native trace yet',
                    message:
                        'The trace is written when a local turn runs. '
                        'Open this screen again after a local reply — or '
                        'after one that timed out.',
                    compact: true,
                  )
                else ...[
                  Text(
                    '${_formatBytes(_traceBytes)}'
                    '${_traceModified != null ? ' · modified ${_formatDate(_traceModified!)}' : ''}',
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
                        onPressed: _traceContents == null
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: _traceContents!),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text('Native trace copied'),
                                    ),
                                  );
                                }
                              },
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Share'),
                        onPressed: _traceContents == null
                            ? null
                            : () => Share.share(
                                _traceContents!,
                                subject: 'Clawzilla native trace',
                              ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Refresh'),
                        onPressed: _loadTraceLog,
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text('Clear'),
                        onPressed: _clearTraceLog,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_traceContents != null && _traceContents!.isEmpty)
                    Text(
                      'The trace file is empty. An empty trace after a '
                      'local turn means the native glue never wrote to it '
                      '— the trace path was never set, or the turn never '
                      'reached the native layer.',
                      style: theme.textTheme.bodyMedium,
                    )
                  else if (_traceContents != null)
                    SelectableText(
                      _traceContents!,
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
