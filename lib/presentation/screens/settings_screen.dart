/// Settings screen with polished UI, smooth animations, enhanced organization,
/// prominent model management, and animated feedback on setting changes.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/log.dart';
import '../../data/database/database_helper.dart';
import '../../data/services/connected_apps_store.dart';
import '../../data/services/model_preflight.dart';
import '../../data/services/secure_store.dart';
import '../../domain/models/cloud_provider.dart';
import '../providers/providers.dart';
import '../widgets/screen_section_card.dart';
import 'cloud_screen.dart';
import 'models_screen.dart';
import 'onboarding_screen.dart';
import 'performance_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _fadeAnimation;
  String? _lastChangedSetting;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _triggerFeedback(String settingKey) {
    setState(() {
      _lastChangedSetting = settingKey;
    });
    _animController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(toolPermissionsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        actions: [
          if (_lastChangedSetting != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Chip(
                    backgroundColor: scheme.primaryContainer,
                    labelStyle: TextStyle(
                      fontSize: 11,
                      color: scheme.onPrimaryContainer,
                    ),
                    label: Text('Updated: $_lastChangedSetting'),
                    avatar: Icon(
                      Icons.check_circle,
                      size: 14,
                      color: scheme.primary,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            // Prominent Models entry point
            FadeSlideIn(
              delay: Duration.zero,
              child: _ProminentModelsSection(
                onChanged: () => _triggerFeedback('models'),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 22),
              child: ScreenSection(
                title: 'Models folder',
                subtitle: 'Where your model files live.',
                padding: EdgeInsets.zero,
                child: _ModelsFolderSetting(
                  onChanged: () => _triggerFeedback('models_folder'),
                ),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 45),
              child: ScreenSection(
                title: 'Assistant & Behavior',
                subtitle:
                    'Fine-tune personality and how much it remembers.',
                padding: EdgeInsets.zero,
                child: _AssistantGroup(
                  onChanged: (key) => _triggerFeedback(key),
                ),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 90),
              child: ScreenSection(
                title: 'Voice & Output',
                subtitle: 'Configure voice replies and listening.',
                padding: EdgeInsets.zero,
                child: VoiceSettings(onChanged: (key) => _triggerFeedback(key)),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 135),
              child: ScreenSection(
                title: 'Privacy & Security',
                subtitle: 'Control what Cypher is allowed to do.',
                padding: EdgeInsets.zero,
                child: PermissionList(permissions: permissions),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 158),
              child: ScreenSection(
                title: 'Connected apps',
                subtitle:
                    'Apps Cypher may open or share to. Off unless you switch one on.',
                padding: EdgeInsets.zero,
                child: _ConnectedAppsSection(
                  onChanged: () => _triggerFeedback('connected_apps'),
                ),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 180),
              child: ScreenSection(
                title: 'Cloud Integration',
                subtitle:
                    'Connect optional cloud endpoints with explicit consent.',
                padding: EdgeInsets.zero,
                child: CloudPrivacySection(
                  onChanged: () => _triggerFeedback('cloud_consent'),
                ),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 225),
              child: ScreenSection(
                title: 'Data & Storage',
                subtitle: 'Manage local database, history, and secure state.',
                padding: EdgeInsets.zero,
                child: const EraseDataSection(),
              ),
            ),
            const SizedBox(height: 24),

            FadeSlideIn(
              delay: const Duration(milliseconds: 270),
              child: ScreenSection(
                title: 'About & Diagnostics',
                subtitle:
                    'Version details, hardware benchmark, and license info.',
                padding: EdgeInsets.zero,
                child: const AboutSection(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prominent Models Card with glowing badge and clear status indicator
class _ProminentModelsSection extends ConsumerWidget {
  const _ProminentModelsSection({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final llmService = ref.read(llmServiceProvider);
    final loaded = llmService.isLoaded;
    final modelPath = llmService.modelPath;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            scheme.primary.withValues(alpha: 0.15),
            scheme.secondary.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.3),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.of(context)
                .push(AppPageRoute(builder: (_) => const ModelsScreen()));
            onChanged();
          },
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/clawzilla-mark.png',
                      width: 28,
                      height: 28,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Models',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: loaded
                                  ? AppColors.success.withValues(alpha: 0.2)
                                  : AppColors.warning.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              loaded ? 'ACTIVE' : 'NO MODEL',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: loaded
                                    ? AppColors.success
                                    : AppColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        loaded && modelPath != null
                            ? 'Loaded: ${ModelPreflight.friendlyName(modelPath.substring(modelPath.lastIndexOf('/') + 1))}'
                            : 'Tap here to download and switch models',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Personality and context size grouped together with custom animations.
class _AssistantGroup extends ConsumerWidget {
  const _AssistantGroup({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              ScreenRowIcon(
                icon: Icons.face_retouching_natural,
                color: scheme.primary,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Personality Style',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tone and behavioral profile of responses',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: PersonalitySelector(
            current: settings['personality'] as String?,
            onChanged: () => onChanged('personality'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ScreenRowDivider(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              ScreenRowIcon(
                icon: Icons.memory_rounded,
                color: scheme.secondary,
                size: 34,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Memory',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'How much of the conversation the model remembers',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ContextSizeSelector(
            current: settings['context_size'] as int?,
            onChanged: () => onChanged('context_size'),
          ),
        ),
      ],
    );
  }
}

/// Permission list widget with enhanced row styling and icons
class PermissionList extends ConsumerWidget {
  final Map<String, String> permissions;

  const PermissionList({super.key, required this.permissions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tools = AppConstants.defaultPermissions.keys.toList();

    return Column(
      children: [
        for (var i = 0; i < tools.length; i++) ...[
          _permissionRow(context, ref, tools[i]),
          if (i != tools.length - 1)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: ScreenRowDivider(),
            ),
        ],
      ],
    );
  }

  Widget _permissionRow(BuildContext context, WidgetRef ref, String tool) {
    final current = permissions[tool] ?? 'ask';
    final theme = Theme.of(context);

    final tint = switch (current) {
      AppConstants.permissionAllow => AppColors.success,
      AppConstants.permissionBlock => AppColors.danger,
      _ => AppColors.warning,
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ScreenRowIcon(icon: _getToolIcon(tool), color: tint, size: 36),
      title: Text(
        _getToolName(tool),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            'Permission: ${current.toUpperCase()}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: tint,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tint.withValues(alpha: 0.4)),
        ),
        child: PopupMenuButton<String>(
          initialValue: current,
          tooltip: 'Select Permission',
          onSelected: (value) {
            ref
                .read(toolPermissionsProvider.notifier)
                .setPermission(tool, value);
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'allow', child: Text('Allow')),
            const PopupMenuItem(value: 'ask', child: Text('Ask')),
            const PopupMenuItem(value: 'block', child: Text('Block')),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current.capitalize(),
                style: TextStyle(
                  color: tint,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.arrow_drop_down, color: tint, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getToolIcon(String tool) {
    switch (tool) {
      case 'send_sms':
        return Icons.sms_outlined;
      case 'create_calendar_event':
        return Icons.event_outlined;
      case 'add_contact':
        return Icons.person_add_alt_1_outlined;
      case 'set_alarm':
        return Icons.alarm_outlined;
      case 'open_app':
        return Icons.apps_outlined;
      case 'web_search':
        return Icons.search;
      case 'get_location':
        return Icons.location_on_outlined;
      case 'create_note':
        return Icons.note_add_outlined;
      case 'read_notes':
        return Icons.library_books_outlined;
      default:
        return Icons.handyman_outlined;
    }
  }

  String _getToolName(String tool) {
    switch (tool) {
      case 'send_sms':
        return 'Send SMS';
      case 'create_calendar_event':
        return 'Calendar Event';
      case 'add_contact':
        return 'Add Contact';
      case 'set_alarm':
        return 'Set Alarm';
      case 'open_app':
        return 'Open App';
      case 'web_search':
        return 'Web Search';
      case 'get_location':
        return 'Get Location';
      case 'create_note':
        return 'Create Note';
      case 'read_notes':
        return 'Read Notes';
      default:
        return tool;
    }
  }
}

/// Personality selector widget with animated cards / choices
class PersonalitySelector extends ConsumerWidget {
  final String? current;
  final VoidCallback onChanged;

  const PersonalitySelector({super.key, this.current, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: AppConstants.personalities.keys.map((personality) {
        final isSelected = current == personality;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? scheme.primary.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: RadioListTile<String>(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              personality.capitalize(),
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? scheme.primary : scheme.onSurface,
              ),
            ),
            subtitle: Text(
              _getPersonalityDescription(personality),
              style: theme.textTheme.bodySmall,
            ),
            value: personality,
            groupValue: current,
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(settingsProvider.notifier)
                    .updateSetting('personality', value);
                onChanged();
              }
            },
          ),
        );
      }).toList(),
    );
  }

  String _getPersonalityDescription(String personality) {
    switch (personality.toLowerCase()) {
      case 'direct':
        return 'Short, concise, and straight to the point.';
      case 'friendly':
        return 'Warm, conversational, and encouraging.';
      case 'professional':
        return 'Formal, precise, and highly structured.';
      default:
        return 'Balanced behavioral style.';
    }
  }
}

/// Voice settings widget with animated SwitchListTile
class VoiceSettings extends ConsumerWidget {
  const VoiceSettings({super.key, required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final ttsEnabled = settings['tts_enabled'] as bool? ?? true;
    final alwaysListening = settings['always_listening'] as bool? ?? false;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SwitchListTile(
            secondary: ScreenRowIcon(
              icon: ttsEnabled
                  ? Icons.record_voice_over_outlined
                  : Icons.voice_over_off_outlined,
              color: ttsEnabled
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              size: 38,
            ),
            title: const Text('Text-to-Speech'),
            subtitle: const Text(
              'Read assistant responses aloud using speech engine',
            ),
            value: ttsEnabled,
            onChanged: (value) {
              ref
                  .read(settingsProvider.notifier)
                  .updateSetting('tts_enabled', value);
              onChanged('tts_enabled');
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SwitchListTile(
            secondary: ScreenRowIcon(
              icon: alwaysListening
                  ? Icons.hearing_outlined
                  : Icons.hearing_disabled_outlined,
              color: alwaysListening
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              size: 38,
            ),
            title: const Text('Always listening — "Hey Cypher"'),
            subtitle: const Text(
              'Cypher listens for its wake word even with the app closed. '
              'All audio stays on the phone. Uses battery while on.',
            ),
            value: alwaysListening,
            onChanged: (value) async {
              ref
                  .read(settingsProvider.notifier)
                  .updateSetting('always_listening', value);
              onChanged('always_listening');
              final wake = ref.read(wakeServiceProvider);
              if (value) {
                final problem = await wake.start();
                if (problem != null) {
                  // Starting failed (no listening model, mic
                  // permission, engine error): flip the toggle back so
                  // it never lies.
                  ref
                      .read(settingsProvider.notifier)
                      .updateSetting('always_listening', false);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(problem)),
                    );
                  }
                }
              } else {
                await wake.stop();
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ListTile(
            leading: ScreenRowIcon(
              icon: Icons.record_voice_over_outlined,
              color: scheme.primary,
              size: 38,
            ),
            title: const Text('Voice'),
            subtitle: Text(
              (settings['tts_voice'] as String? ?? '').isEmpty
                  ? 'System default'
                  : settings['tts_voice'] as String,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showVoicePicker(context, ref),
          ),
        ),
      ],
    );
  }

  /// Pick the voice Cypher speaks in. Tapping a voice previews it and
  /// selects it in one step; the choice is saved and re-applied on the
  /// next start. British (en-GB) voices are listed first — the closest
  /// stock sound to a Geoffrey-style voice. This changes the voice only;
  /// Cypher's persona stays Cypher.
  Future<void> _showVoicePicker(BuildContext context, WidgetRef ref) async {
    final tts = ref.read(textToSpeechProvider.notifier);
    final voices = await tts.getVoices();
    // British first, then US, then everything else, alphabetical inside
    // each group.
    int rank(String locale) => locale.startsWith('en-GB')
        ? 0
        : locale.startsWith('en-US')
            ? 1
            : 2;
    voices.sort((a, b) {
      final r = rank(a['locale'] ?? '').compareTo(rank(b['locale'] ?? ''));
      if (r != 0) return r;
      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final current =
              ref.read(settingsProvider)['tts_voice'] as String? ?? '';
          return AlertDialog(
            title: const Text('Voice'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tap a voice to hear it and use it. For a '
                    'Geoffrey-style voice, pick a British (en-GB) voice. '
                    'If no British voice is listed, install one in your '
                    'phone’s text-to-speech settings.',
                  ),
                  const SizedBox(height: 8),
                  if (voices.isEmpty)
                    const Text(
                      'No voices found. Check your phone’s text-to-speech '
                      'settings and make sure a speech engine is installed.',
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          ListTile(
                            title: const Text('System default'),
                            trailing: current.isEmpty
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () async {
                              await tts.clearVoice();
                              await ref
                                  .read(settingsProvider.notifier)
                                  .updateSetting('tts_voice', '');
                              setLocal(() {});
                            },
                          ),
                          for (final voice in voices)
                            ListTile(
                              title: Text(voice['name'] ?? ''),
                              subtitle: Text(voice['locale'] ?? ''),
                              trailing: current == voice['name']
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () async {
                                await tts.previewVoice(
                                  voice,
                                  'Hello, this is Cypher speaking.',
                                );
                                await ref
                                    .read(settingsProvider.notifier)
                                    .updateSetting(
                                      'tts_voice',
                                      voice['name'] ?? '',
                                    );
                                setLocal(() {});
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Context size selector widget with card styling
class ContextSizeSelector extends ConsumerWidget {
  final int? current;
  final VoidCallback onChanged;

  const ContextSizeSelector({super.key, this.current, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: AppConstants.contextSizes.map((size) {
        final isSelected = current == size;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.secondary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? scheme.secondary.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: RadioListTile<int>(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              '$size',
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? scheme.secondary : scheme.onSurface,
              ),
            ),
            subtitle: Text(
              _getContextDescription(size),
              style: theme.textTheme.bodySmall,
            ),
            value: size,
            groupValue: current,
            onChanged: (value) {
              if (value != null) {
                ref
                    .read(settingsProvider.notifier)
                    .updateSetting('context_size', value);
                onChanged();
              }
            },
          ),
        );
      }).toList(),
    );
  }

  String _getContextDescription(int size) {
    if (size <= 2048) {
      return 'Fast & lightweight. Best for quick Q&A.';
    } else if (size <= 4096) {
      return 'Standard context. Balanced memory and speed.';
    } else {
      return 'Large memory window. Good for long documents.';
    }
  }
}

/// About section widget with icons and clean layout
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  late final Future<String> _version = AppConstants.resolvedVersion();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NavRow(
          icon: Icons.speed,
          title: 'Performance & Benchmark',
          subtitle: 'Backend chipset speed and throughput testing',
          onTap: () => Navigator.of(context)
              .push(AppPageRoute(builder: (_) => const PerformanceScreen())),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ScreenRowDivider(),
        ),
        _NavRow(
          icon: Icons.cloud_queue,
          title: 'Cloud Models',
          subtitle: 'Bring your own API key — optional and secure',
          onTap: () => Navigator.of(context)
              .push(AppPageRoute(builder: (_) => const CloudModelsScreen())),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ScreenRowDivider(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.info_outline),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Version',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    FutureBuilder<String>(
                      future: _version,
                      builder: (context, snap) => Text(
                        snap.data ?? AppConstants.appVersion,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ScreenRowDivider(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.public),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'License',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'MIT License',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ScreenRowDivider(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.brand, AppColors.accent],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/clawzilla-mark.png',
                        width: 20,
                        height: 20,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppConstants.appName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Your private AI assistant — fully on device with local intelligence.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A settings row that navigates: leading icon, two lines, chevron.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListTile(
      leading: ScreenRowIcon(icon: icon),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      onTap: onTap,
    );
  }
}

/// One-time cloud consent.
class CloudPrivacySection extends ConsumerWidget {
  const CloudPrivacySection({super.key, required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final providerId = settings['active_cloud_provider'] as String?;
    final provider = providerId == null ? null : CloudCatalog.byId(providerId);
    final granted = cloudConsentGranted(settings, providerId);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScreenRowIcon(
                icon: granted ? Icons.cloud_done : Icons.cloud_off,
                color: granted ? AppColors.success : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cloud Data Privacy',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      provider == null
                          ? 'No active cloud provider'
                          : provider.displayName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (provider == null)
            Text(
              'No cloud provider is selected, so everything stays on this '
              'phone. Add a provider under Cloud Models to use the cloud, '
              'with your confirmation.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            )
          else ...[
            Text(
              granted
                  ? 'Cloud enabled for ${provider.displayName}. Requests transmit with your authorization.'
                  : 'Cloud disabled for ${provider.displayName}. No data leaves device until confirmed.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 14),
            if (!granted)
              FilledButton.icon(
                onPressed: () {
                  _confirmConsent(context, ref, provider);
                  onChanged();
                },
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text('Enable cloud for ${provider.displayName}'),
              )
            else
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(settingsProvider.notifier).revokeCloudConsent();
                  onChanged();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cloud consent withdrawn.')),
                  );
                },
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Withdraw consent'),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmConsent(
    BuildContext context,
    WidgetRef ref,
    CloudProvider provider,
  ) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send data to ${provider.displayName}?'),
        content: SingleChildScrollView(
          child: Text(
            CloudPrivacy.consentBody(provider.displayName),
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I agree'),
          ),
        ],
      ),
    );

    if (agreed != true) return;
    await ref.read(settingsProvider.notifier).grantCloudConsent(provider.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cloud enabled for ${provider.displayName}.')),
    );
  }
}

/// "Erase all data" — two-step confirmation, then a full wipe.
class EraseDataSection extends ConsumerStatefulWidget {
  const EraseDataSection({super.key});

  @override
  ConsumerState<EraseDataSection> createState() => _EraseDataSectionState();
}

class _EraseDataSectionState extends ConsumerState<EraseDataSection> {
  final TwoStepConfirm _confirm = TwoStepConfirm();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const ScreenRowIcon(
            icon: Icons.delete_forever,
            color: AppColors.danger,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Erase All Data',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.danger,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Permanently delete chat history, memories, notes, documents, and preferences.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: BorderSide(
                      color: AppColors.danger.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _busy ? null : _startErase,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline, size: 18),
                  label: Text(_busy ? 'Erasing…' : 'Erase everything'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startErase() async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Erase all data?'),
        content: const Text(
          'This permanently deletes everything Clawzilla stores on this '
          'device:\n\n'
          '  \u2022  all chat messages\n'
          '  \u2022  memories and notes\n'
          '  \u2022  ingested documents\n'
          '  \u2022  saved cloud API keys\n'
          '  \u2022  all settings\n\n'
          'The app will return to a fresh first-run state.',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (first != true) {
      _confirm.cancel();
      return;
    }
    _confirm.confirmFirst();

    var deleteModels = false;
    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Last chance — this cannot be undone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Are you sure? Once erased, this data cannot be recovered.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: deleteModels,
                onChanged: (v) => setLocal(() => deleteModels = v ?? false),
                title: const Text(
                  'Also delete downloaded models',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  'Frees disk space. Files under '
                  '"${AppConstants.modelsDirName}/" in this app\'s documents '
                  'folder; they can be downloaded again.',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Erase everything'),
            ),
          ],
        ),
      ),
    );

    if (second != true || !_confirm.confirmSecond()) {
      _confirm.cancel();
      return;
    }

    await _runErase(deleteModels);
  }

  Future<void> _runErase(bool deleteModels) async {
    setState(() => _busy = true);
    try {
      await DatabaseHelper.instance.wipe();
      await SecureStore.instance.wipe();

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      if (deleteModels) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          final models = Directory(
            '${docs.path}/${AppConstants.modelsDirName}',
          );
          if (await models.exists()) {
            await models.delete(recursive: true);
          }
          Log.i('erased downloaded models from ${models.path}');
        } catch (e) {
          Log.w('could not delete downloaded models: $e');
        }
      }

      await ref.read(settingsProvider.notifier).resetToDefaults();
      ref.invalidate(chatMessagesProvider);
      ref.invalidate(activityLogProvider);

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        AppPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    } catch (e) {
      Log.e('erase all data failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erase failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}

/// Models folder setting: the folder on the phone that holds model files.
///
/// Picks through the system folder picker. The Models screen lists the
/// folder's files with their header lines and a Load button each.
class _ModelsFolderSetting extends ConsumerWidget {
  const _ModelsFolderSetting({required this.onChanged});

  final VoidCallback onChanged;

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Pick the folder with your models',
    );
    if (path == null) return;
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('models_folder', path);
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final folderRaw =
        ref.watch(settingsProvider)['models_folder'] as String?;
    final folder =
        (folderRaw == null || folderRaw.isEmpty) ? null : folderRaw;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
                  folder ??
                      'No folder picked yet — downloaded models still work '
                          'without one.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: folder == null
                        ? scheme.onSurfaceVariant
                        : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => _pickFolder(context, ref),
                child: Text(folder == null ? 'Pick a folder' : 'Change'),
              ),
            ],
          ),
          if (folder != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () async {
                await ref
                    .read(settingsProvider.notifier)
                    .updateSetting('models_folder', '');
                onChanged();
              },
              child: const Text('Remove folder'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Connected apps: the opt-in list of other apps Cypher may open or share
/// to. Each app is added from the system app picker and starts switched
/// OFF — nothing is openable until Aaron switches it on here.
class _ConnectedAppsSection extends ConsumerStatefulWidget {
  const _ConnectedAppsSection({required this.onChanged});

  final VoidCallback onChanged;

  @override
  ConsumerState<_ConnectedAppsSection> createState() =>
      _ConnectedAppsSectionState();
}

class _ConnectedAppsSectionState
    extends ConsumerState<_ConnectedAppsSection> {
  List<ConnectedAppEntry> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await ConnectedAppsStore.instance.entries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _addApp() async {
    final picked = await ConnectedAppsStore.pickApp();
    if (picked == null || !mounted) return;
    await ConnectedAppsStore.instance.add(
      picked.packageName,
      picked.label,
    );
    widget.onChanged();
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${picked.label} added — switch it on to use it.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_entries.isEmpty)
            Text(
              'No apps connected. Cypher cannot open or share to any app '
              'until you add one and switch it on.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            for (final entry in _entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.label),
                subtitle: Text(
                  entry.packageName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                secondary: IconButton(
                  tooltip: 'Remove ${entry.label}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ConnectedAppsStore.instance.remove(
                      entry.packageName,
                    );
                    widget.onChanged();
                    await _reload();
                  },
                ),
                value: entry.enabled,
                onChanged: (v) async {
                  await ConnectedAppsStore.instance.setEnabled(
                    entry.packageName,
                    v,
                  );
                  widget.onChanged();
                  await _reload();
                },
              ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _addApp,
            icon: const Icon(Icons.add),
            label: const Text('Add an app'),
          ),
        ],
      ),
    );
  }
}
