/// Models screen — pick what you want, then download it in-app.
///
/// Nothing ships inside the APK; every model is streamed from Hugging Face
/// into app-private storage with live progress. The list is grouped by role
/// because the three roles are genuinely different:
///
///   Chat       one GGUF brain. You need exactly one.
///   Vision     a vision-capable GGUF + its mmproj. Qwen3.5 carries its own
///              ViT, so a single download both chats and sees. Moondream2
///              stays listed but disabled: this build of llama.cpp has no
///              encoder for its projector, so it can never load.
///   Embeddings an ONNX encoder + vocab.txt that backs Memory search.
///              Optional, but Memory silently does nothing without it.
///
/// The presentation problem this screen has to solve is that a download is a
/// long, silent wait on a phone. A row that only says "downloading" leaves the
/// user guessing whether it stalled; every row therefore carries its own byte
/// counts, a determinate bar and an explicit percentage, so "how long is left"
/// is answerable without leaving the screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/theme/app_theme.dart';
import '../../data/services/gpu_service.dart';
import '../../data/services/llm_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/model_preflight.dart';
import '../../data/services/storage_models_store.dart';
import '../../domain/models/local_model.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';

class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  final ModelManager _manager = ModelManager.getInstance();

  /// modelId -> latest download progress, so rows survive rebuilds.
  final Map<String, double> _progress = {};
  final Set<String> _busy = {};

  /// modelId -> whether it is fully on disk. Cached from [ModelManager.isInstalled].
  final Map<String, bool> _installed = {};

  /// Single-selection state (legacy)
  String? _activeLlm;
  String? _activeVision;
  String? _activeEmbedding;

  /// Multi-selection state (new)
  List<String> _multiLlmIds = [];
  List<String> _multiVisionIds = [];
  List<String> _multiEmbeddingIds = [];

  int _storageBytes = 0;

  /// True once at least one model has been seen installed on disk.
  ///
  /// Drives the first-run card. It cannot be derived from [_activeLlm]: a user
  /// who downloads a model and never selects it has storage on disk but a null
  /// selection, and would be told they have nothing.
  bool _anythingInstalled = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
    _loadStorage();
    _loadInstalled();
  }

  Future<void> _loadInstalled() async {
    final results = await Future.wait(
      ModelCatalog.all.map((m) async => (m.id, await _manager.isInstalled(m))),
    );
    if (!mounted) return;
    setState(() {
      for (final r in results) {
        _installed[r.$1] = r.$2;
      }
    });
  }

  Future<void> _loadStorage() async {
    final bytes = await _manager.installedBytes();
    // Anything but a zero-byte models directory means at least one file landed
    // there, which is the signal the first-run card needs. Probing every
    // catalogue entry with isInstalled() would cost six directory stats and
    // promise nothing extra.
    final present = bytes > 0;
    if (!mounted) return;
    setState(() {
      _storageBytes = bytes;
      if (present) _anythingInstalled = true;
    });
  }

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MB';
    if (b <= 0) return '0 MB';
    return '${(b / (1 << 10)).round()} KB';
  }

  Future<void> _loadSelection() async {
    // Load both single and multi selection
    final List<dynamic> results = await Future.wait([
      Future.wait<String?>([
        _manager.activeLlmId(),
        _manager.activeVisionId(),
        _manager.activeEmbeddingId(),
      ]),
      Future.wait<List<String>>([
        _manager.activeLlmIds(),
        _manager.activeVisionIds(),
        _manager.activeEmbeddingIds(),
      ]),
    ]);

    final List<String?> ids = results[0] as List<String?>;
    final List<List<String>> multiLists = results[1] as List<List<String>>;

    if (!mounted) return;
    setState(() {
      _activeLlm = ids[0];
      _activeVision = ids[1];
      _activeEmbedding = ids[2];
      _multiLlmIds = multiLists[0];
      _multiVisionIds = multiLists[1];
      _multiEmbeddingIds = multiLists[2];
    });
  }

  /// Write [m] into the selection slot its **section** belongs to.
  ///
  /// Dispatching on `m.kind` sends Qwen3.5 to `activeVisionId` no matter which
  /// section it was tapped in, because it is registered as
  /// [ModelKind.vision] while also being a perfectly good chat model. Tapping
  /// it under "Chat model" therefore left `activeLlmId` on a different model
  /// and Load bound the wrong one. The section is the authority.
  Future<void> _select(LocalModel m, bool installed, ModelKind section) async {
    switch (section) {
      case ModelKind.llm:
        if (installed) {
          await _manager.selectLlm(m.id);
        } else {
          await _manager.setActiveLlmId(null);
        }
        break;
      case ModelKind.vision:
        await _manager.selectVision(installed ? m.id : null);
        break;
      case ModelKind.embedding:
        await _manager.setActiveEmbeddingId(installed ? m.id : null);
        break;
    }
    await _loadSelection();
  }

  /// Toggle [m] in the multi-selection list for [section].
  ///
  /// If the model is already selected, remove it; otherwise add it.
  Future<void> _toggleMultiSelect(
    LocalModel m,
    bool installed,
    ModelKind section,
  ) async {
    if (!installed) return;

    List<String> current;
    switch (section) {
      case ModelKind.llm:
        current = List.from(_multiLlmIds);
        break;
      case ModelKind.vision:
        current = List.from(_multiVisionIds);
        break;
      case ModelKind.embedding:
        current = List.from(_multiEmbeddingIds);
        break;
    }

    if (current.contains(m.id)) {
      current.remove(m.id);
    } else {
      current.add(m.id);
    }

    switch (section) {
      case ModelKind.llm:
        await _manager.setActiveLlmIds(current);
        break;
      case ModelKind.vision:
        await _manager.setActiveVisionIds(current);
        break;
      case ModelKind.embedding:
        await _manager.setActiveEmbeddingIds(current);
        break;
    }
    await _loadSelection();
  }

  Future<void> _download(LocalModel m, ModelKind section) async {
    if (_busy.contains(m.id)) return;
    setState(() => _busy.add(m.id));

    final completer = Completer<void>();
    late StreamSubscription sub;

    void finish() {
      if (!completer.isCompleted) completer.complete();
      sub.cancel();
      if (mounted) {
        setState(() {
          _busy.remove(m.id);
          _progress.remove(m.id);
        });
      }
    }

    sub = _manager
        .download(m)
        .listen(
          (p) {
            if (!mounted) return;
            setState(() => _progress[m.id] = p.fraction ?? 0.0);
            if (p.error != null) {
              finish();
              _toast('${m.displayName}: ${p.error}');
              return;
            }
            if (p.done) {
              _installed[m.id] = true;
              finish();
              // Selecting straight after a successful download saves a tap.
              _select(m, true, section);
              _toggleMultiSelect(m, true, section);
              _loadStorage();
              _loadInstalled(); // refresh install cache
              _toast('${m.displayName} installed');
            }
          },
          onError: (Object e) {
            finish();
            _toast('Download failed: $e');
          },
          onDone: finish,
          cancelOnError: true,
        );

    await completer.future;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Models'),
        actions: [
          // Show how many models are selected across all categories
          if (_multiLlmIds.isNotEmpty ||
              _multiVisionIds.isNotEmpty ||
              _multiEmbeddingIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Tooltip(
                message: 'Total selected models',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_multiLlmIds.length + _multiVisionIds.length + _multiEmbeddingIds.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _storageCard(theme, scheme),
          _ModelsFolderSection(onLoaded: _loadStorage),
          _MyModelsSection(onLoaded: _loadStorage),
          if (!_anythingInstalled) ...[
            const SizedBox(height: 4),
            _firstRunCard(),
          ],
          const SizedBox(height: 8),
          _sectionHeader(
            'Chat model',
            'The brain. Tap to select one or more models. Needs ~600 MB RAM each.',
            _multiLlmIds,
          ),
          ...ModelCatalog.llms.map(
            (m) => _row(
              m,
              selectedId: _activeLlm,
              multiIds: _multiLlmIds,
              section: ModelKind.llm,
            ),
          ),
          const Divider(height: 32),
          _sectionHeader(
            'Vision model',
            'Lets the agent read pictures. Qwen3.5 has vision built in, so one download is enough — it chats and sees. Any entry greyed out cannot run on this phone yet.',
            _multiVisionIds,
          ),
          ...ModelCatalog.visionModels.map(
            (m) => _row(
              m,
              selectedId: _activeVision,
              multiIds: _multiVisionIds,
              section: ModelKind.vision,
              usable: ModelCatalog.isUsable(m),
            ),
          ),
          const Divider(height: 32),
          _sectionHeader(
            'Embeddings',
            'Powers Memory search. Without it, past conversations are stored but never retrieved.',
            _multiEmbeddingIds,
          ),
          ...ModelCatalog.embeddingModels.map(
            (m) => _row(
              m,
              selectedId: _activeEmbedding,
              multiIds: _multiEmbeddingIds,
              section: ModelKind.embedding,
            ),
          ),
          if (_multiLlmIds.isNotEmpty ||
              _multiVisionIds.isNotEmpty ||
              _multiEmbeddingIds.isNotEmpty)
            ..._selectedModelsList(theme, scheme),
        ],
      ),
    );
  }

  Widget _sectionHeader(
    String title,
    String subtitle,
    List<String> selectedIds,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 3),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (selectedIds.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.layers, size: 13, color: AppColors.success),
                  const SizedBox(width: 4),
                  Text(
                    '${selectedIds.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.success,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _selectedModelsList(ThemeData theme, ColorScheme scheme) {
    final allSelected = <LocalModel>[];
    for (final id in _multiLlmIds) {
      final m = ModelCatalog.byId(id);
      if (m != null) allSelected.add(m);
    }
    for (final id in _multiVisionIds) {
      final m = ModelCatalog.byId(id);
      if (m != null) allSelected.add(m);
    }
    for (final id in _multiEmbeddingIds) {
      final m = ModelCatalog.byId(id);
      if (m != null) allSelected.add(m);
    }

    if (allSelected.isEmpty) return [];

    return [
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Selected Models',
          style: theme.textTheme.titleSmall?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      ...allSelected.map((m) {
        bool isSelectedInLlm = _multiLlmIds.contains(m.id);
        bool isSelectedInVision = _multiVisionIds.contains(m.id);
        bool isSelectedInEmbedding = _multiEmbeddingIds.contains(m.id);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Card(
            color: scheme.primary.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              side: BorderSide(
                color: scheme.primary.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    m.kind == ModelKind.embedding
                        ? Icons.dns_outlined
                        : m.kind == ModelKind.vision
                        ? Icons.visibility_outlined
                        : Icons.psychology_outlined,
                    color: AppColors.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.displayName,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (isSelectedInLlm) ...[
                              _roleChip('LLM', scheme, theme.textTheme),
                              const SizedBox(width: 4),
                            ],
                            if (isSelectedInVision) ...[
                              _roleChip('Vision', scheme, theme.textTheme),
                              const SizedBox(width: 4),
                            ],
                            if (isSelectedInEmbedding) ...[
                              _roleChip('Embed', scheme, theme.textTheme),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () async {
                      await _removeFromMultiSelect(m, ModelKind.llm);
                      await _removeFromMultiSelect(m, ModelKind.vision);
                      await _removeFromMultiSelect(m, ModelKind.embedding);
                    },
                    tooltip: 'Remove from selection',
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    ];
  }

  Widget _roleChip(String label, ColorScheme scheme, TextTheme text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: text.labelSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _removeFromMultiSelect(LocalModel m, ModelKind section) async {
    switch (section) {
      case ModelKind.llm:
        if (!_multiLlmIds.contains(m.id)) return;
        await _manager.setActiveLlmIds(
          _multiLlmIds.where((id) => id != m.id).toList(),
        );
        break;
      case ModelKind.vision:
        if (!_multiVisionIds.contains(m.id)) return;
        await _manager.setActiveVisionIds(
          _multiVisionIds.where((id) => id != m.id).toList(),
        );
        break;
      case ModelKind.embedding:
        if (!_multiEmbeddingIds.contains(m.id)) return;
        await _manager.setActiveEmbeddingIds(
          _multiEmbeddingIds.where((id) => id != m.id).toList(),
        );
        break;
    }
    if (mounted) await _loadSelection();
  }

  /// Storage used, plus the fact that models live on the device.
  ///
  /// This is the first thing on the screen on purpose: "how much space does
  /// this app hold" is the question people have here after a few hundred
  /// megabytes has appeared, and the answer was previously at the very bottom
  /// of a scrolling list, after every catalogue entry.
  Widget _storageCard(ThemeData theme, ColorScheme scheme) {
    final used = _storageBytes > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _StorageDial(used: used),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      used
                          ? '${_fmtBytes(_storageBytes)} of models'
                          : 'No models yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Models are stored on this device and never leave it. '
                      'They keep working with no network at all.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// First run: say what is missing and give the one action that fixes it.
  ///
  /// The button calls the same [_download] the row does, with the same
  /// section, so the fast path and the full path cannot drift apart — a
  /// separate bespoke download here is how a "recommended" entry ends up not
  /// selecting the model it just fetched.
  Widget _firstRunCard() {
    final recommended = ModelCatalog.defaultLlm;

    return ScreenEmptyState(
      icon: Icons.download_for_offline_outlined,
      title: 'Download a model to start chatting',
      message:
          'Nothing is bundled with the app, so there is no assistant until a '
          'model is on this device. ${recommended.displayName} '
          '(${recommended.sizeLabel}) is the best balance for most phones.',
      actionLabel: 'Download ${recommended.displayName}',
      actionIcon: Icons.download,
      onAction: () => _download(recommended, ModelKind.llm),
      compact: true,
    );
  }

  Widget _row(
    LocalModel m, {
    required String? selectedId,
    required List<String> multiIds,
    required ModelKind section,
    bool usable = true,
  }) {
    final installed = _installed[m.id] ?? false;
    final selected = installed && selectedId == m.id;
    final busy = _busy.contains(m.id);
    final progress = _progress[m.id];

    return _ModelRowShell(
      child: _ModelRow(
        model: m,
        installed: installed,
        selected: selected,
        multiSelected: multiIds.contains(m.id),
        usable: usable,
        busy: busy,
        progress: progress,
        onDelete: () async {
          await _manager.delete(m);
          _installed[m.id] = false;
          await _loadSelection();
          await _loadStorage();
          if (mounted) {
            setState(() {});
            _toast('${m.displayName} deleted');
          }
        },
        onDownload: () => _download(m, section),
        onSelect: () async {
          if (!installed) {
            await _download(m, section);
          } else {
            await _select(m, true, section);
            await _toggleMultiSelect(m, true, section);
            if (mounted) setState(() {});
          }
        },
        onToggleMulti: () async {
          if (installed) {
            await _toggleMultiSelect(m, true, section);
          }
        },
      ),
    );
  }
}

/// A circular storage readout.
///
/// A dial rather than a bare number because the useful comparison is "how much
/// of my phone is this", and a bar communicates that without a second label.
class _StorageDial extends StatelessWidget {
  const _StorageDial({required this.used});

  /// Whether anything is installed; drives the icon and its tint.
  final bool used;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = used ? AppColors.accent : scheme.onSurfaceVariant;

    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(
        used ? Icons.sd_storage : Icons.sd_storage_outlined,
        size: 22,
        color: tint,
      ),
    );
  }
}

/// Padding + tap target shared by every row, so rows line up whether they are
/// showing real content or the loading placeholder.
class _ModelRowShell extends StatelessWidget {
  const _ModelRowShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: child,
    );
  }
}

/// One model row: identity, state, and the controls that change it.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.installed,
    required this.selected,
    required this.multiSelected,
    required this.usable,
    required this.busy,
    required this.progress,
    required this.onDelete,
    required this.onDownload,
    required this.onSelect,
    required this.onToggleMulti,
  });

  final LocalModel model;
  final bool installed;
  final bool selected;
  final bool multiSelected;
  final bool usable;
  final bool busy;
  final double? progress;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final VoidCallback onSelect;
  final VoidCallback onToggleMulti;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: selected || multiSelected
          ? scheme.primary.withValues(alpha: 0.10)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        side: BorderSide(
          color: (selected || multiSelected)
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        onTap: usable ? onSelect : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _RoleIcon(
                  kind: model.kind,
                  usable: usable,
                  selected: selected,
                  multiSelected: multiSelected,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: usable ? null : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(model.description, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    _MetaLine(model: model),
                    const SizedBox(height: 8),
                    _StateBadge(
                      installed: installed,
                      selected: selected,
                      multiSelected: multiSelected,
                      usable: usable,
                      busy: busy,
                    ),
                    if (model.unsupportedReason != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              model.unsupportedReason!,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (busy && progress != null) ...[
                      const SizedBox(height: 10),
                      _DownloadProgress(
                        fraction: progress!,
                        sizeLabel: model.sizeLabel,
                      ),
                    ],
                  ],
                ),
              ),
              _RowActions(
                busy: busy,
                installed: installed,
                usable: usable,
                onDelete: onDelete,
                onDownload: onDownload,
                onToggleMulti: onToggleMulti,
                multiSelected: multiSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Role glyph: the three roles are genuinely different, so they get different
/// shapes rather than three labels in the same circle.
class _RoleIcon extends StatelessWidget {
  const _RoleIcon({
    required this.kind,
    required this.usable,
    required this.selected,
    required this.multiSelected,
  });

  final ModelKind kind;
  final bool usable;
  final bool selected;
  final bool multiSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = !usable
        ? scheme.onSurfaceVariant
        : selected || multiSelected
        ? scheme.primary
        : kind == ModelKind.embedding
        ? AppColors.accent
        : AppColors.brand;

    final icon = switch (kind) {
      ModelKind.llm => Icons.psychology_outlined,
      ModelKind.vision => Icons.visibility_outlined,
      // Icons.embed_outlined does not exist in the Material icon set (only
      // embed/embed_rounded/embed_sharp do), which the analyzer does not catch
      // but the kernel snapshot does. dns_outlined reads as "stored vectors"
      // and is already used elsewhere in the app.
      ModelKind.embedding => Icons.dns_outlined,
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(usable ? icon : Icons.block, size: 19, color: tint),
    );
  }
}

/// Size and RAM.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.model});

  final LocalModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final parts = <String>[
      if (model.ramHint.isNotEmpty) model.ramHint,
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          model.sizeLabel,
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
        for (final p in parts)
          Text(p, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
      ],
    );
  }
}

/// The explicit state word. Colour alone would fail here: "downloaded" and
/// "not downloaded" differ by the same few pixels, and this list is scanned in
/// bad light on a phone held at arm's length.
class _StateBadge extends StatelessWidget {
  const _StateBadge({
    required this.installed,
    required this.selected,
    required this.multiSelected,
    required this.usable,
    required this.busy,
  });

  final bool installed;
  final bool selected;
  final bool multiSelected;
  final bool usable;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    late final String label;
    late final Color tint;
    late final IconData icon;

    if (!usable) {
      label = 'Unavailable on this build';
      tint = theme.colorScheme.onSurfaceVariant;
      icon = Icons.block;
    } else if (busy) {
      label = 'Downloading';
      tint = AppColors.accent;
      icon = Icons.downloading;
    } else if (multiSelected) {
      label = 'Multi-selected';
      tint = AppColors.success;
      icon = Icons.check_circle;
    } else if (selected) {
      label = 'Selected';
      tint = AppColors.success;
      icon = Icons.check_circle;
    } else if (installed) {
      label = 'Downloaded';
      tint = AppColors.success;
      icon = Icons.check_circle_outline;
    } else {
      label = 'Not downloaded';
      tint = theme.colorScheme.onSurfaceVariant;
      icon = Icons.cloud_download_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Determinate bar plus the two numbers that make "how long" answerable.
///
/// A bar alone is a progress bar; a bar with a percentage and a byte count is
/// a progress bar *and* an ETA. Users comparing a 400 MB model against a 1.1 GB
/// one need the total to judge whether to switch, not just the rate.
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.fraction, required this.sizeLabel});

  final double fraction;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (fraction.clamp(0.0, 1.0) * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '$pct%',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text('of $sizeLabel', style: theme.textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

/// Trailing controls: busy spinner, delete, or download.
///
/// Kept as a separate widget so the button order and enablement rules live in
/// one place — they used to be a nested ternary inside the row, where the
/// `busy` branch shadowed the delete button and made an in-flight model
/// impossible to remove.
class _RowActions extends StatelessWidget {
  const _RowActions({
    required this.busy,
    required this.installed,
    required this.usable,
    required this.onDelete,
    required this.onDownload,
    required this.onToggleMulti,
    required this.multiSelected,
  });

  final bool busy;
  final bool installed;
  final bool usable;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final VoidCallback onToggleMulti;
  final bool multiSelected;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }

    if (installed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: multiSelected ? 'Deselect' : 'Select',
            icon: Icon(
              multiSelected ? Icons.check_circle : Icons.add_circle_outline,
              size: 20,
            ),
            onPressed: onToggleMulti,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      );
    }

    return IconButton(
      tooltip: usable ? 'Download' : 'Not supported yet',
      icon: Icon(
        Icons.cloud_download_outlined,
        color: usable ? null : Theme.of(context).disabledColor,
      ),
      onPressed: usable ? onDownload : null,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 3),
          Text(subtitle, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The models folder: a folder on the phone that holds model files, picked
/// in Settings. Downloads land here too, so the folder is the one place a
/// model file lives whether it came from the app or from elsewhere.
///
/// Each file shows its header line (name, kind, size) from the inspector,
/// and a Load button that runs the same safe load the chat screen uses —
/// header check and RAM gate first, never silent, never a crash. A file
/// that fails the header check shows why and has no Load button.
class _ModelsFolderSection extends ConsumerStatefulWidget {
  const _ModelsFolderSection({required this.onLoaded});

  /// Called after a folder file loads, so the storage card above refreshes.
  final VoidCallback onLoaded;

  @override
  ConsumerState<_ModelsFolderSection> createState() =>
      _ModelsFolderSectionState();
}

class _ModelsFolderSectionState
    extends ConsumerState<_ModelsFolderSection> {
  Future<List<_FolderFile>>? _filesFuture;
  String? _folderError;
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final folder =
        ref.read(settingsProvider)['models_folder'] as String?;
    if (folder == null || folder.isEmpty) {
      setState(() {
        _filesFuture = null;
        _folderError = null;
      });
      return;
    }
    setState(() {
      _folderError = null;
      _filesFuture = _listFolderFiles(folder);
    });
  }

  Future<List<_FolderFile>> _listFolderFiles(String folder) async {
    try {
      final dir = Directory(folder);
      final entries = await dir.list().toList();
      // Every non-hidden file, not just .gguf ones: a model file that lost
      // its extension (Qwen3.5-2B) is still a loadable GGUF, and a file
      // that is not one shows its header error instead of a Load button.
      // The preflight check below decides which is which.
      final files = entries
          .whereType<File>()
          .where((f) => !f.path.split('/').last.startsWith('.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final out = <_FolderFile>[];
      for (final f in files) {
        // One unreadable file must not kill the whole listing.
        try {
          final info = await ModelPreflight.inspect(f.path);
          final error =
              info == null ? await ModelPreflight.verify(f.path) : null;
          out.add(_FolderFile(path: f.path, info: info, error: error));
        } catch (_) {
          out.add(
            _FolderFile(
              path: f.path,
              info: null,
              error: 'Could not read this file.',
            ),
          );
        }
      }
      return out;
    } catch (_) {
      if (mounted) {
        setState(() {
          _folderError = 'Could not open that folder — pick it again.';
        });
      }
      return <_FolderFile>[];
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Pick the folder with your models',
    );
    if (path == null || !mounted) return;
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('models_folder', path);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _loadFile(_FolderFile file) async {
    setState(() => _loadingPath = file.path);
    try {
      final ram = await GpuService.detect();
      final ok = await LlmService.getInstance().loadModel(
        file.path,
        totalRamMb: ram.totalRamMb,
      );
      if (!mounted) return;
      if (ok) {
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('model_path', file.path);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Loaded ${file.info?.name ?? ModelPreflight.friendlyName(file.fileName)}',
            ),
          ),
        );
        widget.onLoaded();
      } else {
        // Surface the actual reason, like the chat picker does — a bare
        // "Could not load that model." hides whether the engine rejected
        // the file, the file is too big, or the header failed.
        final reason = LlmService.getInstance().lastLoadError;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not load that model'
              '${reason == null ? '' : ': $reason'}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPath = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final folderRaw =
        ref.watch(settingsProvider)['models_folder'] as String?;
    final folder =
        (folderRaw == null || folderRaw.isEmpty) ? null : folderRaw;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Models folder',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: _pickFolder,
                    child: Text(folder == null ? 'Pick a folder' : 'Change'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                folder == null
                    ? 'Point the app at the folder where you keep model '
                          'files, and they show up here ready to load.'
                    : folder,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (folder != null) ...[
                const SizedBox(height: 8),
                if (_folderError != null)
                  Text(
                    _folderError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  )
                else if (_filesFuture == null)
                  const SizedBox.shrink()
                else
                  FutureBuilder<List<_FolderFile>>(
                    future: _filesFuture,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      final files = snap.data ?? const <_FolderFile>[];
                      if (files.isEmpty) {
                        return Text(
                          'No model files in this folder yet.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final f in files) ...[
                            const Divider(height: 16),
                            _FolderFileRow(
                              file: f,
                              loading: _loadingPath == f.path,
                              onLoad: () => _loadFile(f),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The user's own models, as custom slots.
///
/// The same slots the chat picker shows under "My models", here on the
/// Models screen: every model loaded from storage earns a slot (most
/// recent first, max 8), tap one to load it, X removes just the slot —
/// the file stays on the phone. The slots live in [StorageModelsStore]
/// (the phone's database), so they show up even when the folder listing
/// above cannot read the folder, and a slot survives a restart.
class _MyModelsSection extends ConsumerStatefulWidget {
  const _MyModelsSection({required this.onLoaded});

  final VoidCallback onLoaded;

  @override
  ConsumerState<_MyModelsSection> createState() => _MyModelsSectionState();
}

class _MyModelsSectionState extends ConsumerState<_MyModelsSection> {
  List<String> _storageModels = [];
  String? _loadingPath;

  /// Hugging Face import (Nov 11, 2026): paste a file link, the app pulls
  /// the GGUF in. The link field, download progress, and cancel live here
  /// so a finished import can refresh this card's list directly.
  final TextEditingController _hfController = TextEditingController();
  bool _hfDownloading = false;
  int _hfReceived = 0;
  int? _hfTotal;
  String? _hfError;
  http.Client? _hfClient;
  bool _hfCancelRequested = false;

  @override
  void initState() {
    super.initState();
    _loadStorageModels();
  }

  @override
  void dispose() {
    _hfController.dispose();
    _hfClient?.close();
    super.dispose();
  }

  Future<void> _loadStorageModels() async {
    final all = await StorageModelsStore.instance.entries();
    final kept = <String>[];
    for (final p in all) {
      if (File(p).existsSync()) {
        kept.add(p);
      } else {
        await StorageModelsStore.instance.remove(p);
      }
    }
    if (!mounted) return;
    setState(() => _storageModels = kept);
  }

  Future<void> _loadPath(String path) async {
    setState(() => _loadingPath = path);
    try {
      final ram = await GpuService.detect();
      final ok = await LlmService.getInstance().loadModel(
        path,
        totalRamMb: ram.totalRamMb,
      );
      if (!mounted) return;
      if (ok) {
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('model_path', path);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Loaded ${ModelPreflight.friendlyName(path.split('/').last)}',
            ),
          ),
        );
        widget.onLoaded();
        _loadStorageModels();
      } else {
        final reason = LlmService.getInstance().lastLoadError;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not load that model'
              '${reason == null ? '' : ': $reason'}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingPath = null);
    }
  }

  /// Pull a GGUF in straight from Hugging Face (Nov 11, 2026 — Aaron asked
  /// for a paste-a-link import).
  ///
  /// The link must be a direct file link — the one from the file's download
  /// button on Hugging Face, `huggingface.co/<owner>/<repo>/resolve/<branch>
  /// /<file>.gguf`. A file *page* link (`/blob/`) is rewritten to `/resolve/`;
  /// a model *page* link has no file to pull in, so it is refused with a
  /// message saying which link to copy. Only `.gguf` files are accepted.
  ///
  /// This is a direct download, not a catalog download: there is no pinned
  /// integrity manifest for an arbitrary link, so no SHA check happens here.
  /// The file is still verified when it is loaded (the GGUF header check),
  /// and Aaron's bring-along-scan gates still apply before use. The file
  /// lands in the app's models folder as `<name>.part` first and is only
  /// renamed once the download completes, so an interrupted import never
  /// leaves a file the loader would trip over. It is then registered in
  /// "My models" so it shows up here with a Load button.
  Future<void> _importFromHuggingFace() async {
    final raw = _hfController.text.trim();
    if (raw.isEmpty || _hfDownloading) return;
    File? tmp;
    setState(() {
      _hfError = null;
      _hfDownloading = true;
      _hfReceived = 0;
      _hfTotal = null;
      _hfCancelRequested = false;
    });
    try {
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host != 'huggingface.co') {
        throw const FormatException('That is not a Hugging Face link.');
      }
      var path = uri.path;
      if (path.contains('/blob/')) {
        path = path.replaceFirst('/blob/', '/resolve/');
      }
      if (!path.contains('/resolve/')) {
        throw const FormatException(
          'That is a model page, not a file. Open the file on Hugging Face '
          'and copy its download link instead.',
        );
      }
      final fileName = path.split('/').last;
      if (fileName.isEmpty ||
          !fileName.toLowerCase().endsWith('.gguf')) {
        throw const FormatException(
          'That link does not point to a .gguf file.',
        );
      }
      final dir = await ModelManager.getInstance().modelsDir();
      final target = File('${dir.path}/$fileName');
      if (await target.exists()) {
        throw const FormatException(
          'That file is already in the models folder.',
        );
      }
      tmp = File('${target.path}.part');
      final client = http.Client();
      _hfClient = client;
      final response = await client.send(
        http.Request('GET', uri.replace(path: path)),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'Hugging Face answered ${response.statusCode}.',
        );
      }
      if (mounted) setState(() => _hfTotal = response.contentLength);
      final sink = tmp.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          if (!mounted) break;
          setState(() => _hfReceived += chunk.length);
        }
      } finally {
        await sink.close();
      }
      if (_hfCancelRequested) return;
      await tmp.rename(target.path);
      tmp = null;
      await StorageModelsStore.instance.add(target.path);
      if (!mounted) return;
      _hfController.clear();
      await _loadStorageModels();
      widget.onLoaded();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $fileName')),
      );
    } catch (e) {
      // A failed or cancelled import never leaves a partial file behind.
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _hfError = _hfCancelRequested
              ? 'Download cancelled.'
              : e is FormatException
                  ? e.message
                  : 'Download failed: $e';
        });
      }
    } finally {
      _hfClient?.close();
      _hfClient = null;
      if (mounted) setState(() => _hfDownloading = false);
    }
  }

  /// Cancel an in-flight Hugging Face import. Closing the client aborts the
  /// request; the import catches it, deletes the partial file, and reports
  /// it as a cancellation, not an error.
  void _cancelHuggingFaceImport() {
    _hfCancelRequested = true;
    _hfClient?.close();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentPath =
        ref.watch(settingsProvider)['model_path'] as String?;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'My models',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Models you loaded from storage. Tap one to load it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              if (_storageModels.isEmpty)
                Text(
                  'Empty — load a model from storage and it will sit here.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              else
                for (var i = 0; i < _storageModels.length; i++) ...[
                  const Divider(height: 16),
                  _MyModelRow(
                    filePath: _storageModels[i],
                    isCurrent: currentPath == _storageModels[i],
                    loading: _loadingPath == _storageModels[i],
                    onLoad: () => _loadPath(_storageModels[i]),
                    onRemove: () async {
                      await StorageModelsStore.instance
                          .remove(_storageModels[i]);
                      if (!mounted) return;
                      setState(
                        () => _storageModels.removeAt(i),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Removed from My models. The file is still on the phone.',
                          ),
                        ),
                      );
                    },
                  ),
                ],
              // Import from Hugging Face: paste a file link, the app pulls
              // the GGUF in (Nov 11, 2026). It lands in the models folder
              // and shows up here with a Load button.
              const Divider(height: 24),
              Text(
                'Import from Hugging Face',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Paste a file link from Hugging Face and the app pulls the '
                'model in. Use the file\'s download link, not the model page.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hfController,
                      decoration: const InputDecoration(
                        hintText:
                            'https://huggingface.co/.../resolve/.../*.gguf',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _importFromHuggingFace(),
                      enabled: !_hfDownloading,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        _hfDownloading ? null : _importFromHuggingFace,
                    child: const Text('Import'),
                  ),
                ],
              ),
              if (_hfDownloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _hfTotal != null && _hfTotal! > 0
                      ? _hfReceived / _hfTotal!
                      : null,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _hfTotal != null && _hfTotal! > 0
                            ? '${_ModelsScreenState._fmtBytes(_hfReceived)} / ${_ModelsScreenState._fmtBytes(_hfTotal!)}'
                            : '${_ModelsScreenState._fmtBytes(_hfReceived)} downloaded',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelHuggingFaceImport,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
              if (_hfError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _hfError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One "My models" slot: the file name, its size, whether it is the
/// loaded one, and an X that removes just the slot.
class _MyModelRow extends StatelessWidget {
  const _MyModelRow({
    required this.filePath,
    required this.isCurrent,
    required this.loading,
    required this.onLoad,
    required this.onRemove,
  });

  final String filePath;
  final bool isCurrent;
  final bool loading;
  final VoidCallback onLoad;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fileName = filePath.split('/').last;
    final name = ModelPreflight.friendlyName(fileName);
    String size = '';
    try {
      size = _ModelsScreenState._fmtBytes(File(filePath).lengthSync());
    } catch (_) {
      size = '';
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.description_outlined,
            size: 18,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(
                [
                  if (size.isNotEmpty) size,
                  isCurrent ? 'Loaded' : 'Tap to load this model',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(10),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          TextButton(onPressed: onLoad, child: const Text('Load')),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Remove this slot (the file stays on the phone)',
            onPressed: onRemove,
          ),
        ],
      ],
    );
  }
}

/// One model file found in the models folder.
class _FolderFile {
  const _FolderFile({required this.path, required this.info, this.error});

  final String path;
  final ModelInfo? info;

  /// The header-check error when [info] is null — shown instead of a
  /// Load button, so a bad file is explained, not hidden.
  final String? error;

  String get fileName => path.substring(path.lastIndexOf('/') + 1);
}

class _FolderFileRow extends StatelessWidget {
  const _FolderFileRow({
    required this.file,
    required this.loading,
    required this.onLoad,
  });

  final _FolderFile file;
  final bool loading;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bad = file.info == null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            bad ? Icons.warning_amber_outlined : Icons.description_outlined,
            size: 18,
            color: bad ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.info?.summaryLine ??
                    ModelPreflight.friendlyName(file.fileName),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: bad ? scheme.error : null,
                ),
              ),
              if (file.error != null) ...[
                const SizedBox(height: 2),
                Text(
                  file.error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(10),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (!bad)
          TextButton(onPressed: onLoad, child: const Text('Load')),
      ],
    );
  }
}
