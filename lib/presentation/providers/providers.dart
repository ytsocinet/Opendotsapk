/// Riverpod providers for state management
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/log.dart';
import '../../data/services/llm_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/mcp_service.dart';
import '../../data/services/router_service.dart';
import '../../data/services/secure_store.dart';
import '../../data/services/wake_service.dart';
import '../../data/tools/tool_registry.dart';
import '../../data/tools/tool_permission_store.dart';
import '../../data/database/database_helper.dart';
import '../../domain/agents/agent_orchestrator.dart';
import '../../domain/models/models.dart';

// LLM Service Provider
final llmServiceProvider = Provider<LlmService>((ref) {
  return LlmService.getInstance();
});

// Cloud LLM Service (bring-your-own-key)
final cloudServiceProvider = Provider<CloudService>((ref) {
  return CloudService.instance;
});

// MCP client — extends the tool set beyond the built-in nine
final mcpServiceProvider = Provider<McpService>((ref) {
  return McpService.instance;
});

// Keystore-backed storage for API keys and the database key
final secureStoreProvider = Provider<SecureStore>((ref) {
  return SecureStore.instance;
});

// Local/cloud routing
final routerServiceProvider = Provider<RouterService>((ref) {
  return RouterService.instance;
});

// Embedding Service Provider
final embeddingServiceProvider = Provider<EmbeddingService>((ref) {
  return EmbeddingService.getInstance();
});

// Tool Registry Provider
final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  return ToolRegistry();
});

// Database Helper Provider
final databaseProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

// Agent Orchestrator Provider
final agentOrchestratorProvider = Provider<AgentOrchestrator>((ref) {
  return AgentOrchestrator();
});

// Speech to Text Provider
final speechToTextProvider = StateNotifierProvider<SpeechNotifier, bool>((ref) {
  return SpeechNotifier();
});

class SpeechNotifier extends StateNotifier<bool> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;
  final List<String> _words = [];

  /// The in-flight listen's completer, if any. The engine ends a session
  /// without a final result when it hears no match or when it is stopped,
  /// and waiting on `finalResult` alone left the mic lit for the full
  /// 30-second timeout in exactly those cases — the button looked stuck,
  /// and tapping it again did nothing. The status and error callbacks
  /// below resolve the listen the moment the engine actually stops.
  Completer<String?>? _activeCompleter;

  SpeechNotifier() : super(false);

  Future<void> init() async {
    _isAvailable = await _speech.initialize(
      onStatus: (status) {
        debugPrint('Speech status: $status');
        if (status == 'done' || status == 'notListening') {
          _resolveActive();
        }
      },
      onError: (error) {
        debugPrint('Speech error: $error');
        _resolveActive();
      },
    );
    state = _isAvailable;
  }

  /// Resolve the in-flight listen with whatever words were captured, or
  /// null when nothing was heard. No-op when nothing is listening.
  void _resolveActive() {
    final completer = _activeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(_words.isEmpty ? null : _words.join(' '));
    }
  }

  /// Listens and resolves with the recognised text once the user stops
  /// speaking. `listen()` itself returns void, so the result must be captured
  /// through the callback channel (the previous signature never compiled).
  Future<String?> listenOnce({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_isAvailable) return null;
    _words.clear();

    final completer = Completer<String?>();
    _activeCompleter = completer;

    await _speech.listen(
      listenFor: timeout,
      pauseFor: const Duration(seconds: 3),
      onResult: (result) {
        if (result.recognizedWords.isNotEmpty) {
          _words
            ..clear()
            ..add(result.recognizedWords);
        }
        if (result.finalResult && !completer.isCompleted) {
          completer.complete(_words.isEmpty ? null : _words.join(' '));
        }
      },
    );

    // Safety net if the engine never reports back at all. Kill the
    // session too, so a stale listen cannot swallow the next listen's
    // callbacks.
    try {
      return await completer.future.timeout(
        timeout + const Duration(seconds: 2),
        onTimeout: () async {
          await _speech.cancel();
          return _words.isEmpty ? null : _words.join(' ');
        },
      );
    } finally {
      if (identical(_activeCompleter, completer)) _activeCompleter = null;
    }
  }

  Future<void> stopListening() async {
    await _speech.stop();
  }
}

// Text to Speech Provider
final textToSpeechProvider = StateNotifierProvider<TtsNotifier, bool>((ref) {
  return TtsNotifier(ref);
});

class TtsNotifier extends StateNotifier<bool> {
  final Ref ref;
  final FlutterTts _tts = FlutterTts();
  bool _isReady = false;

  /// Name of the voice currently applied to the engine, when the user
  /// picked one. Null means the engine's own default for the language.
  String? _voiceName;

  /// Pitch currently applied to the engine. 1.0 is normal, lower is
  /// deeper. The user picks it with the Pitch slider in Settings.
  double _pitch = 1.0;

  /// The pitch currently applied to the engine.
  double get pitch => _pitch;

  TtsNotifier(this.ref) : super(false);

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    // Apply the saved pitch (default 1.0). Read defensively: the stored
    // form is a string, and a stale value falls back to normal.
    final rawPitch = ref.read(settingsProvider)['tts_pitch'];
    final savedPitch = rawPitch is double
        ? rawPitch
        : double.tryParse(rawPitch.toString()) ?? 1.0;
    _pitch = savedPitch.clamp(0.5, 2.0).toDouble();
    await _tts.setPitch(_pitch);
    await _tts.setSpeechRate(0.5);
    // Re-apply the voice the user picked, if any. setVoice must come
    // after setLanguage or the language call resets the engine to its
    // default voice. A missing voice (engine changed, voice removed)
    // falls back to the default instead of breaking speech.
    final saved = ref.read(settingsProvider)['tts_voice'] as String?;
    if (saved != null && saved.isNotEmpty) {
      try {
        await _applyVoiceByName(saved);
      } catch (_) {
        // Keep the default voice; speech still works.
      }
    }
    _isReady = true;
    state = true;
  }

  /// The voices the speech engine offers, as name + locale maps.
  /// Entries without a name are skipped; the list is unfiltered so the
  /// picker can sort British (en-GB) voices first.
  Future<List<Map<String, String>>> getVoices() async {
    final raw = await _tts.getVoices;
    final voices = <Map<String, String>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString() ?? '';
      final locale = entry['locale']?.toString() ?? '';
      if (name.isEmpty) continue;
      voices.add({'name': name, 'locale': locale});
    }
    return voices;
  }

  /// Apply [voice] to the engine right now and remember its name so
  /// init() can re-apply it on the next start.
  Future<void> setVoice(Map<String, String> voice) async {
    if (!_isReady) await init();
    await _tts.setVoice(voice);
    _voiceName = voice['name'];
  }

  /// Hear [text] in [voice] and keep that voice selected. Used by the
  /// voice picker so tapping a voice previews it and selects it in one
  /// step. Does not use speak()'s completion tracking — a preview is
  /// fire-and-forget, and a tap on another voice cuts it off.
  Future<void> previewVoice(Map<String, String> voice, String text) async {
    if (!_isReady) await init();
    await _tts.stop();
    await _tts.setVoice(voice);
    _voiceName = voice['name'];
    await _tts.speak(text);
  }

  /// Drop back to the engine's default voice for the language.
  Future<void> clearVoice() async {
    if (!_isReady) await init();
    await _tts.setLanguage('en-US');
    _voiceName = null;
  }

  /// Apply a saved voice by name, if the engine still offers it.
  Future<void> _applyVoiceByName(String name) async {
    final voices = await getVoices();
    final match = voices.where((v) => v['name'] == name).toList();
    if (match.isEmpty) return;
    await _tts.setVoice(match.first);
    _voiceName = name;
  }

  /// Apply [pitch] to the engine right now and remember it so init() can
  /// re-apply it on the next start. Clamped to the engine's 0.5–2.0
  /// range; below 1.0 is deeper. Called by the Pitch slider on every
  /// move, so it saves each step — a local key-value write, cheap enough
  /// for a drag.
  Future<void> setPitch(double pitch) async {
    if (!_isReady) await init();
    final clamped = pitch.clamp(0.5, 2.0).toDouble();
    _pitch = clamped;
    await _tts.setPitch(clamped);
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('tts_pitch', clamped);
  }

  /// Hear a sample in the current voice at the current pitch. Fire-and-
  /// forget like previewVoice: a tap on another control cuts it off.
  Future<void> previewPitch() async {
    if (!_isReady) await init();
    await _tts.stop();
    await _tts.speak('Hello, this is Cypher speaking.');
  }

  /// Speak [text] aloud, waiting until the utterance actually finishes.
  ///
  /// Two fixes in one: `init()` was never called anywhere, so `_isReady`
  /// stayed false and every reply was silently skipped; and awaiting
  /// `speak()` alone returns when synthesis *starts*, so an auto-listen
  /// chained after it would hear Cypher's own voice. The completion
  /// handler marks the real end, with a duration estimate as a safety net
  /// if the engine never reports back.
  Future<void> speak(String text) async {
    if (!_isReady) await init();
    if (text.trim().isEmpty) return;
    final done = Completer<void>();
    _tts.setCompletionHandler(() {
      if (!done.isCompleted) done.complete();
    });
    _tts.setErrorHandler((_) {
      if (!done.isCompleted) done.complete();
    });
    _tts.setCancelHandler(() {
      if (!done.isCompleted) done.complete();
    });
    await _tts.speak(text);
    // ~150 words a minute, plus a margin; never wait forever.
    final words = text.trim().split(RegExp(r'\s+')).length;
    final estimate = Duration(seconds: (words / 2.5).ceil() + 3);
    final cap = estimate > const Duration(seconds: 120)
        ? const Duration(seconds: 120)
        : estimate;
    await done.future.timeout(cap, onTimeout: () {});
  }

  Future<void> stop() async {
    await _tts.stop();
  }
}

// Wake word ("Hey Cypher") — see lib/data/services/wake_service.dart.
final wakeServiceProvider = Provider<WakeService>((ref) {
  return WakeService.instance;
});

/// One saved chat (a "side chat"). The list is newest-active first; the
/// title comes from the first user message.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String? ?? 'New chat',
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }

  final String id;
  final String title;
  final int updatedAt;
}

/// The active conversation's id, shared by the drawer and the chat screen.
final activeConversationIdProvider = StateProvider<String?>((ref) => null);

/// The saved chats shown in the drawer.
final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, List<Conversation>>((ref) {
      return ConversationsNotifier(ref);
    });

class ConversationsNotifier extends StateNotifier<List<Conversation>> {
  ConversationsNotifier(this.ref) : super([]) {
    refresh();
  }

  final Ref ref;
  final DatabaseHelper _db = DatabaseHelper.instance;

  Future<void> refresh() async {
    final rows = await _db.getConversations();
    // One unreadable row must not throw away the whole list: parse
    // each row on its own and skip (with a log line) the ones that fail.
    final parsed = <Conversation>[];
    for (final row in rows) {
      try {
        parsed.add(Conversation.fromMap(row));
      } catch (e) {
        Log.w('conversations: skipping unreadable row: $e');
      }
    }
    state = parsed;
  }

  /// Starts a new chat and switches to it.
  Future<void> createNew() async {
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.createConversation(id: id, title: 'New chat', timestamp: now);
    await refresh();
    await ref.read(chatMessagesProvider.notifier).loadConversation(id);
    // Re-read once the switch has landed, so the list the drawer shows
    // is the list that is actually in the database now.
    await refresh();
  }

  /// Opens an existing chat.
  Future<void> switchTo(String id) async {
    await ref.read(chatMessagesProvider.notifier).loadConversation(id);
    await refresh();
  }

  /// Deletes a chat and all its messages. If it was the open one, the most
  /// recent remaining chat opens; if none remains, a fresh one is created.
  Future<void> delete(String id) async {
    final wasActive = ref.read(activeConversationIdProvider) == id;
    await _db.deleteConversation(id);
    await refresh();
    if (!wasActive) return;
    if (state.isNotEmpty) {
      await ref
          .read(chatMessagesProvider.notifier)
          .loadConversation(state.first.id);
    } else {
      final freshId = const Uuid().v4();
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.createConversation(
        id: freshId,
        title: 'New chat',
        timestamp: now,
      );
      await refresh();
      await ref
          .read(chatMessagesProvider.notifier)
          .loadConversation(freshId);
    }
  }
}

// Chat Messages Provider
final chatMessagesProvider =
    StateNotifierProvider<ChatNotifier, List<ChatMessage>>((ref) {
      return ChatNotifier(ref);
    });

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  final Ref ref;
  final DatabaseHelper _db = DatabaseHelper.instance;

  /// The conversation these messages belong to. Null until the first load
  /// makes sure one exists.
  String? _conversationId;

  /// Memoised so a send racing the first load cannot create two "New chat"
  /// rows: both callers share the one in-flight creation.
  Future<String>? _ensureFuture;

  ChatNotifier(this.ref) : super([]) {
    _init();
  }

  Future<void> _init() async {
    // The active conversation lives in its own provider so the drawer can
    // switch it; if none is set yet (fresh install, or an upgrade that
    // predates conversations), make sure one exists first.
    var id = ref.read(activeConversationIdProvider);
    if (id == null) {
      id = await _ensureConversation();
      // The user may have tapped New chat or switched chats while this
      // first load was still in flight; never clobber a newer choice
      // with the stale one this load started with.
      final current = ref.read(activeConversationIdProvider);
      if (current != null) {
        id = current;
      } else {
        ref.read(activeConversationIdProvider.notifier).state = id;
      }
    }
    _conversationId = id;
    await _loadMessages();
  }

  /// The id of a conversation to load: the most recent one, or a fresh
  /// "New chat" when there is none yet.
  Future<String> _ensureConversation() {
    return _ensureFuture ??= _pickOrCreateConversation();
  }

  Future<String> _pickOrCreateConversation() async {
    final rows = await _db.getConversations();
    if (rows.isNotEmpty) return rows.first['id'] as String;
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.createConversation(id: id, title: 'New chat', timestamp: now);
    // The drawer list loads separately; refresh it so the new row shows.
    unawaited(ref.read(conversationsProvider.notifier).refresh());
    return id;
  }

  Future<void> loadConversation(String id) async {
    _conversationId = id;
    ref.read(activeConversationIdProvider.notifier).state = id;
    await _loadMessages();
  }

  Future<void> _loadMessages() async {
    final messages = await _db.getRecentMessages(
      limit: 100,
      conversationId: _conversationId,
    );
    state = messages
        .map((m) => ChatMessage.fromMap(m))
        .toList()
        .reversed
        .toList();
  }

  Future<void> addMessage(ChatMessage message) async {
    // The composer can fire before the first load finished; make sure the
    // message lands in a conversation rather than nowhere.
    var id = _conversationId;
    if (id == null) {
      id = await _ensureConversation();
      _conversationId = id;
      ref.read(activeConversationIdProvider.notifier).state = id;
    }
    await _db.insertMessage(
      id: message.id,
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      conversationId: id,
    );
    await _db.touchConversation(id: id, timestamp: message.timestamp);
    state = [message, ...state];
    // First user message names the chat: "New chat" becomes the first few
    // words of what was actually asked. Later messages leave the title
    // alone.
    if (message.role == 'user') {
      await _maybeTitleConversation(id, message.content);
    }
    unawaited(ref.read(conversationsProvider.notifier).refresh());
  }

  Future<void> _maybeTitleConversation(String id, String content) async {
    final rows = await _db.getConversations();
    final row = rows.where((r) => r['id'] == id).toList();
    if (row.isEmpty) return;
    if ((row.first['title'] as String?) != 'New chat') return;
    await _db.updateConversationTitle(id: id, title: _titleFrom(content));
  }

  /// A chat title from the first message: one line, short enough for the
  /// drawer row.
  String _titleFrom(String content) {
    final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return 'New chat';
    if (oneLine.length <= 40) return oneLine;
    return '${oneLine.substring(0, 39).trimRight()}…';
  }

  Future<void> clearChat() async {
    // Clearing used to empty only the in-memory list, so the messages came
    // back from the database on the next launch. Now it deletes this
    // conversation's messages for real; the conversation itself stays in
    // the list, empty.
    final id = _conversationId;
    if (id != null) {
      await _db.deleteMessagesForConversation(id);
    }
    state = [];
  }
}

// Tool Permissions Provider
final toolPermissionsProvider =
    StateNotifierProvider<PermissionsNotifier, Map<String, String>>((ref) {
      return PermissionsNotifier();
    });

/// Tool permissions, backed by the single [ToolPermissionStore].
///
/// This used to keep its own hardcoded map and a `_loadPermissions` that read
/// nothing back, so every restart silently reset the user's choices — and the
/// agent consulted a *different* map anyway. There is now one persisted store,
/// and this notifier is only a view onto it.
class PermissionsNotifier extends StateNotifier<Map<String, String>> {
  final ToolPermissionStore _store = ToolPermissionStore();

  PermissionsNotifier() : super({}) {
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    // The registry has to be populated before we can enumerate tools.
    // `registerTools` is idempotent, so calling it here as well as at startup
    // is safe and makes this provider self-sufficient.
    final registry = ToolRegistry()..registerTools();
    await _store.load(registry.tools.keys);
    state = {
      for (final entry in _store.all.entries) entry.key: entry.value.wire,
    };
  }

  Future<void> setPermission(String tool, String permission) async {
    await _store.set(tool, ToolPermission.parse(permission));
    state = Map.from(state)..[tool] = permission;
  }
}

// Activity Log Provider
final activityLogProvider =
    StateNotifierProvider<ActivityLogNotifier, List<Map<String, dynamic>>>((
      ref,
    ) {
      return ActivityLogNotifier();
    });

class ActivityLogNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  final DatabaseHelper _db = DatabaseHelper.instance;

  ActivityLogNotifier() : super([]) {
    _loadLog();
  }

  Future<void> _loadLog() async {
    state = await _db.getActivityLog(limit: 100);
  }

  Future<void> refresh() async {
    await _loadLog();
  }
}

// Settings Provider
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, Map<String, dynamic>>((ref) {
      return SettingsNotifier();
    });

/// The privacy facts a cloud consent step must state.
///
/// Kept in one place so the consent UI, the code that decides whether consent
/// is needed, and any test all describe exactly the same data. If a new kind of
/// payload is added to a cloud request, it must be listed here or the consent
/// text becomes a lie.
class CloudPrivacy {
  CloudPrivacy._();

  /// What actually leaves the device when a turn is sent to a cloud provider.
  static const List<String> leavesDevice = [
    'the text of your prompt',
    'your recent conversation history',
    'the text of any attached document',
    'any images you attach',
  ];

  /// Plain-English body for the opt-in dialog naming the destination provider.
  static String consentBody(String providerDisplayName) {
    final items = leavesDevice.map((e) => '  \u2022  $e').join('\n');
    return 'If you turn cloud on, the following will be sent over the '
        'internet to $providerDisplayName:\n\n$items\n\n'
        'Once sent, it is handled under that provider\'s own privacy policy, '
        'not this app\'s. Nothing is sent until you agree, the on-device model '
        'stays the default, and you can withdraw this at any time.';
  }
}

/// Whether the stored consent already covers [providerId].
///
/// Consent is bound to a specific destination: switching the active provider
/// makes this return false again, which is what forces the opt-in step to be
/// shown a second time. Consent is *not* inherited by a new provider.
bool cloudConsentGranted(Map<String, dynamic> settings, String? providerId) {
  if (providerId == null || providerId.isEmpty) return false;
  final consented = settings['cloud_consent_provider'];
  return consented is String && consented == providerId;
}

/// One-shot "send the next message to the cloud, just this once" flag.
///
/// This is the per-message affordance. It is deliberately *state* rather than a
/// setting: it applies to exactly one outgoing turn and is consumed as that
/// turn is sent, so a single tap can never leak more than one message. It never
/// overrides private mode — see [routeConfigForTurn].
final cloudOnceProvider = StateNotifierProvider<CloudOnceNotifier, bool>((ref) {
  return CloudOnceNotifier();
});

class CloudOnceNotifier extends StateNotifier<bool> {
  CloudOnceNotifier() : super(false);

  /// Arm the override for the next message.
  void armForNextMessage() => state = true;

  /// Read and clear the flag. Returns true when a one-shot cloud send was armed.
  bool consume() {
    final armed = state;
    if (armed) state = false;
    return armed;
  }
}

/// Enforces that a destructive action is confirmed twice.
///
/// A single dialog with one confirm button is one step. This gate refuses to
/// report completion unless the caller first recorded the first step, so "Erase
/// all data" cannot be triggered by a stray tap or a mis-wired single dialog —
/// the second confirmation only counts if the first genuinely happened.
class TwoStepConfirm {
  bool _firstDone = false;

  /// Whether the first confirmation has been given and not yet consumed.
  bool get awaitingSecond => _firstDone;

  /// Record the first confirmation.
  void confirmFirst() => _firstDone = true;

  /// Record the second confirmation. Returns true only when the first step had
  /// already been taken; always clears the gate afterwards so it cannot be
  /// reused for a second erase without going through both steps again.
  bool confirmSecond() {
    final ok = _firstDone;
    _firstDone = false;
    return ok;
  }

  /// Abandon the flow (e.g. the user cancelled at the second dialog).
  void cancel() => _firstDone = false;
}

class SettingsNotifier extends StateNotifier<Map<String, dynamic>> {
  /// The conservative first-run defaults. Extracted so "Erase all data" can
  /// restore exactly this state without a second copy of the map drifting from
  /// the constructor's.
  static Map<String, dynamic> _defaults() => {
    'context_size': 2048,
    'personality': 'professional',
    'tts_enabled': true,
    // Name of the TTS voice the user picked in Settings. Empty means the
    // engine's own default voice for the language.
    'tts_voice': '',
    // TTS pitch the user picked in Settings (1.0 is normal, lower is
    // deeper). The engine clamps it to 0.5–2.0.
    'tts_pitch': 1.0,
    'voice_enabled': true,
    // Cypher always-listening ("Hey Cypher"). Off by default: it keeps
    // the mic warm and runs a foreground service, so it is opt-in.
    'always_listening': false,
    // Background mode: keep the app alive while Cypher works on a long
    // reply, with a "done" notice when it finishes. On by default: it
    // only holds a wake lock while a task actually runs.
    'background_mode': true,
    // Core skills (build #91; eleven skills from build #94): the Shemue
    // core skills folded into Cypher's system prompt. On by default: the
    // section is short lines, so it costs almost no context. Each skill
    // also has its own toggle (skill_*), default on; the master switch
    // is the overall kill switch.
    'core_skills': true,
    'skill_ponytail': true,
    'skill_planning_with_files': true,
    'skill_adhd': true,
    'skill_taste': true,
    'skill_diagram': true,
    'skill_gbrain': true,
    'skill_agent_reach': true,
    'skill_hyperframes': true,
    'skill_cybersecurity': true,
    'skill_scientific': true,
    'skill_dashboard': true,
    'model_path': null,

    // Cloud / privacy. Defaults are the conservative ones: auto routing,
    // private mode off, and metered connections biased to the local model.
    'cloud_mode': 'auto',
    'private_mode': false,
    'prefer_local_metered': true,
    'active_cloud_provider': null,
    'active_cloud_model': null,

    // Cloud consent, bound to a specific provider id. Null means "not granted
    // for anything", so a fresh install never routes to the cloud without the
    // opt-in step.
    'cloud_consent_provider': null,

    // Security
    'biometric_lock': false,

    // Compute backend: auto | gpu | cpu. 'auto' follows GpuService, which
    // stays on the CPU for midrange Mali parts where the GPU usually loses.
    'gpu_offload': 'auto',

    // Number of CPU threads for inference (1-4). The default of 4 is a safe
    // starting point for most phones; reduce to 2 or 1 if you experience
    // thermal throttling or OOM on low-end devices.
    'cpu_threads': 4,

    // First-run
    'onboarding_done': false,

    // Chat mode: chat | plan | code. Chat is the plain default; Plan
    // plans before acting, Code answers about code. See chat_screen.
    'chat_mode': 'chat',

    // Thinking effort: low | med | high. Only a reply-length and
    // step-by-step hint, not a true reasoning budget on a local model.
    'thinking_effort': 'med',

    // Models folder: a folder on the phone that holds model files,
    // picked in Settings. Null means "no folder picked yet".
    'models_folder': null,

    // Projects folder: a folder on the phone that holds the user's
    // project files, picked in Settings. Null means "no folder picked
    // yet". The IDE edits files here, and Cypher may read and write
    // inside it too.
    'projects_folder': null,

    // Theme colour: the accent the whole app is seeded from, stored as
    // the colour's ARGB int. Matrix green by default.
    'theme_color': 0xFF00FF66,

    // Message timestamps: '12h' (2:17 PM) or '24h' (14:17). 12-hour by
    // default.
    'time_format': '12h',

    // Last file opened in the IDE (from Projects). The IDE drawer tile
    // reopens it; null means none yet.
    'last_ide_file': null,

    // Connected apps (opt-in, off by default): a JSON list of Android
    // package names Cypher may open or share to. Empty means none.
    'connected_apps': '[]',
  };

  final DatabaseHelper _db = DatabaseHelper.instance;

  SettingsNotifier() : super(_defaults()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final contextSize = await _db.getPreference('context_size');
    if (contextSize != null) {
      state = Map.from(state)..['context_size'] = int.parse(contextSize);
    }

    // Pitch is a double; stored as its string form, parsed back here.
    // tryParse so a stale or hand-edited value falls back to normal.
    final ttsPitch = await _db.getPreference('tts_pitch');
    if (ttsPitch != null) {
      state = Map.from(state)
        ..['tts_pitch'] = double.tryParse(ttsPitch) ?? 1.0;
    }

    final personality = await _db.getPreference('personality');
    if (personality != null) {
      state = Map.from(state)..['personality'] = personality;
    }

    final ttsEnabled = await _db.getPreference('tts_enabled');
    if (ttsEnabled != null) {
      state = Map.from(state)..['tts_enabled'] = ttsEnabled == 'true';
    }

    // Booleans need explicit string parsing; `as bool` would throw on 'true'.
    for (final key in [
      'private_mode',
      'prefer_local_metered',
      'biometric_lock',
      'voice_enabled',
      'always_listening',
      'background_mode',
      'core_skills',
      'skill_ponytail',
      'skill_planning_with_files',
      'skill_adhd',
      'skill_taste',
      'skill_diagram',
      'skill_gbrain',
      'skill_agent_reach',
      'skill_hyperframes',
      'skill_cybersecurity',
      'skill_scientific',
      'skill_dashboard',
      'onboarding_done',
    ]) {
      final raw = await _db.getPreference(key);
      if (raw != null) {
        state = Map.from(state)..[key] = raw == 'true';
      }
    }

    for (final key in [
      'cloud_mode',
      'active_cloud_provider',
      'active_cloud_model',
      'model_path',
      'gpu_offload',
      'cpu_threads',
      'cloud_consent_provider',
      'chat_mode',
      'thinking_effort',
      'models_folder',
      'projects_folder',
      'connected_apps',
      'tts_voice',
      'time_format',
      'last_ide_file',
    ]) {
      final raw = await _db.getPreference(key);
      if (raw != null && raw.isNotEmpty) {
        state = Map.from(state)..[key] = raw;
      }
    }

    // Theme colour is an int (ARGB), stored as its decimal string form.
    // It was missing from the load list when the setting landed (build
    // #85), so a picked colour reset to green on the next launch; fixed
    // in build #86.
    final themeColor = await _db.getPreference('theme_color');
    if (themeColor != null) {
      state = Map.from(state)
        ..['theme_color'] = int.tryParse(themeColor) ?? 0xFF00FF66;
    }

    // Mirror private mode onto the router *before* any probe runs, so the
    // probe is correctly skipped when private mode is on (a DNS lookup is a
    // network call, and private mode promises none).
    RouterService.instance.privateMode =
        state['private_mode'] as bool? ?? false;

    // Keep the router's view of connectivity fresh.
    await RouterService.instance.probeConnectivity();
  }

  Future<void> updateSetting(String key, dynamic value) async {
    state = Map.from(state)..[key] = value;

    // Private mode is also a router concern: flipping it must take effect
    // immediately so the connectivity probe starts/stops respecting it.
    if (key == 'private_mode') {
      RouterService.instance.privateMode = value == true;
    }

    if (value is String) {
      await _db.savePreference(key, value);
    } else if (value is int) {
      await _db.savePreference(key, value.toString());
    } else if (value is double) {
      await _db.savePreference(key, value.toString());
    } else if (value is bool) {
      await _db.savePreference(key, value.toString());
    }
  }

  /// Record that the user consented to sending data to [providerId]. Persisted,
  /// so the opt-in step is shown once per destination rather than on every
  /// launch. Consent is bound to that id: if the destination provider later
  /// changes, [cloudConsentGranted] no longer matches and the step is shown
  /// again.
  Future<void> grantCloudConsent(String providerId) =>
      updateSetting('cloud_consent_provider', providerId);

  /// Withdraw consent for the current destination. An empty value is treated as
  /// "no consent" on the next load, so the opt-in step is shown again.
  Future<void> revokeCloudConsent() =>
      updateSetting('cloud_consent_provider', '');

  /// Restore the conservative first-run defaults after a full erase, so the app
  /// presents a clean first-run state without a relaunch.
  Future<void> resetToDefaults() async {
    state = _defaults();
    RouterService.instance.privateMode = false;
  }
}

// In-app browser — open-URL requests from chat.
//
// A link tapped in a chat message writes the URL here; the Browser tab reads
// it and clears it (MainScreen switches to the tab, BrowserScreen loads it).
// Aaron-only by design (Nov 7, 2026): the agent gets no tool that writes
// this — the agent page-reader is a future step, explicitly decided that day,
// not part of this batch.
final browserOpenRequestProvider = StateProvider<String?>((ref) => null);

/// Tapping the Code mode button in chat writes here; MainScreen reads it
/// and opens the IDE (the last file, or the Projects tab when there is
/// none yet). A counter, not a nullable value: every tap increments it,
/// so tapping Code again still fires, and nothing needs clearing after.
final ideOpenRequestProvider = StateProvider<int>((ref) => 0);
