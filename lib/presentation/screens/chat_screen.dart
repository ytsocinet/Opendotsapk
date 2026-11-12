/// Main chat screen
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../providers/providers.dart';
import '../widgets/chat_composer.dart';
import '../widgets/chat_empty_state.dart';
import '../widgets/chat_message_tile.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/log.dart';
import '../../core/utils/text_utils.dart';
import '../../core/utils/turn_builder.dart';
import '../../data/services/assistant_launch.dart';
import '../../data/services/document_service.dart';
import '../../data/services/gpu_service.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/model_preflight.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/location_weather_service.dart';
import '../../data/services/router_service.dart';
import '../../data/services/storage_models_store.dart';
import '../../data/services/wake_service.dart';
import '../../data/tools/tool_registry.dart';
import '../widgets/biometric_gate.dart';
import '../../domain/models/local_model.dart';
import '../../domain/models/models.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// True when the user has scrolled away from the latest end of the chat.
  ///
  /// The list used to yank back to the bottom on every token flush, so the
  /// user could not read an earlier message while the model was answering.
  /// When this is set, the streaming auto-scroll stands down; the view only
  /// returns to the bottom when an answer finishes (force) or the user
  /// scrolls back down themselves.
  bool _userScrolledAway = false;

  /// The composer focus node.
  final FocusNode _composerFocus = FocusNode();
  final Uuid _uuid = const Uuid();
  bool _isThinking = false;
  String _currentResponse = '';

  /// Where the user is and what the temperature is, for the system prompt.
  /// Fetched in the background (free Open-Meteo + Nominatim, no key) and
  /// cached 30 minutes; null until the first fetch lands or when the
  /// location permission is off, so the prompt just omits it.
  final _locationWeather = LocationWeatherService();
  String? _locationLine;

  /// Special tokens the model may emit as ordinary text. They are
  /// end-of-turn markers for the machine, not words for the user —
  /// stripped once when a reply finishes, so no token from any model
  /// ever shows up in a reply.
  ///
  /// Three layers. Pipe-delimited tokens (`<|eot_id|>`,
  /// `<|im_end|>`, any `<|...|>`) are stripped anywhere — no
  /// legitimate text uses that shape. The known bare stop tokens
  /// (Gemma's `<end_of_turn>` / `<start_of_turn>`, `<bos>` / `<eos>` /
  /// `<s>` / `</s>`, Llama 2's `[INST]` / `<<SYS>>`) are stripped
  /// anywhere too. And anything token-like still sitting at the very
  /// start or end of the reply is stripped in a loop, which is where
  /// a new model's stop token lands even when its name is one we have
  /// never seen. The middle of a reply is left alone for bare
  /// `<...>` — a code answer can legitimately contain `<String>` or
  /// `<div>`, and stripping those would corrupt it.
  static final _pipeToken = RegExp(r'<\|[^|>]+\|>');
  static final _bareStopToken = RegExp(
    r'<end_of_turn>|<start_of_turn>|<end_of_message>|<end_of_text>|'
    r'<begin_of_text>|<end_of_sentence>|<begin_of_sentence>|'
    r'<bos>|<eos>|<pad>|<unk>|<sep>|<cls>|<mask>|<s>|</s>|'
    r'\[INST\]|\[/INST\]|<<SYS>>|<\</SYS>>',
  );
  static final _leadingToken =
      RegExp(r'^(<\|[^|>]+\|>|</?(?!think>)[A-Za-z][A-Za-z0-9_]*>)');
  static final _trailingToken =
      RegExp(r'(<\|[^|>]+\|>|</?(?!think>)[A-Za-z][A-Za-z0-9_]*>)$');

  /// `<think>` and `</think>` are deliberately NOT stripped above: they are
  /// structural, not special tokens. `splitThinking` needs both tags to hide
  /// the model's reasoning in its collapsible section, and the stripper
  /// used to eat a leading `<think>` — leaving the thinking text and a
  /// bare `</think>` visible inline in the answer.

  static String _stripSpecialTokens(String text) {
    var out = text.trim();
    out = out.replaceAll(_pipeToken, '');
    out = out.replaceAll(_bareStopToken, '');
    var prev = '';
    while (prev != out) {
      prev = out;
      out = out.replaceFirst(_leadingToken, '').trimLeft();
      out = out.replaceFirst(_trailingToken, '').trimRight();
    }
    return out.trimRight();
  }

  /// Local file paths of images queued for the next turn.
  ///
  /// Held as paths rather than bytes: the vision model reads from disk, and
  /// keeping base64 in widget state would balloon memory during a long chat.
  final List<String> _attachedImages = [];

  /// Documents ingested this session, available as RAG context.
  final List<IngestedDocument> _attachedDocs = [];

  /// The in-flight cloud request, held so Stop can actually cancel it. The
  /// local path is stopped through `LlmService.stop()` instead.
  StreamSubscription<String>? _cloudSub;

  /// The completer `_sendViaCloud` awaits. Held so Stop can release the wait:
  /// cancelling the subscription alone never completes it (cancel does not
  /// fire onDone/onError), so without this the cloud turn would hang at
  /// `await completer.future` forever and the Stop button would stick.
  Completer<void>? _cloudCompleter;

  /// Set when the user asks to stop. The token loop checks it and **keeps the
  /// partial text** rather than throwing away a half-finished reply.
  bool _stopRequested = false;

  /// True while the current exchange started by voice. Drives Cypher's
  /// auto-listen: after a spoken reply it listens again, but never after
  /// a typed message.
  bool _voiceExchange = false;

  /// True while the mic is listening. Lights the composer mic button up
  /// and lets a tap on it stop the listen.
  bool _isListening = false;

  /// Set when the user taps the lit mic to stop a listen on purpose, so
  /// the empty-result path knows not to show "Didn't catch that".
  bool _voiceStopRequested = false;

  /// Counts listens, so a listen that ends late cannot darken the mic
  /// while a newer listen is already running (see [_startVoiceInput]).
  int _listenGeneration = 0;

  /// Wake service handle, kept so dispose can unregister without ref.
  WakeService? _wake;

  /// Tokens waiting to be shown.
  ///
  /// `setState` used to run once per token, rebuilding this entire screen
  /// hundreds of times a second for no visible benefit. Tokens now accumulate
  /// here and are flushed on a timer.
  String _pendingTokens = '';
  Timer? _flushTimer;

  /// When the in-flight reply started, so its bubble shows a stable clock
  /// instead of one that creeps forward with every rebuild.
  int _streamStartMs = 0;

  @override
  void initState() {
    super.initState();
    _wake = ref.read(wakeServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    AssistantLaunch.setListenHandler(() {
      if (mounted) _startVoiceInput();
    });
    // Runs after the first frame so settings are loaded and the context
    // is usable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreLastModel();
      _restoreWakeListening();
      _checkAssistantLaunch();
      _refreshLocationWeather();
    });
  }

  /// Tracks whether the user has scrolled away from the latest end, so the
  /// streaming auto-scroll can stand down while they read earlier messages.
  ///
  /// In the reversed list, offset 0 is the latest end (the bottom). More than
  /// a little way up means the user is reading history, not watching the
  /// reply come in. No setState: nothing on screen depends on this flag, it
  /// only gates the auto-scroll.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    _userScrolledAway = _scrollController.offset > 120;
  }

  /// The side button (or the "Talk to Cypher" deep link) opened the app
  /// and asked for the mic straight away. Consume the flag once — a
  /// later resume must not re-trigger listening.
  Future<void> _checkAssistantLaunch() async {
    if (!mounted) return;
    if (await AssistantLaunch.consumeListenRequest()) {
      _startVoiceInput();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final wake = _wake;
      if (wake != null && wake.wakePending) {
        wake.wakePending = false;
        _startVoiceInput();
      } else {
        _checkAssistantLaunch();
      }
    }
  }

  /// Load the remembered model on startup, if one was saved and the file
  /// is still there. Same pre-flight checks as a manual load, on CPU.
  /// A missing or bad file shows an error instead of crashing or silently
  /// doing nothing; a success shows on the "Loaded model" card.
  Future<void> _restoreLastModel() async {
    if (!mounted) return;
    final llm = ref.read(llmServiceProvider);
    if (llm.isLoaded) return;
    final path = ref.read(settingsProvider)['model_path'] as String?;
    if (path == null || path.trim().isEmpty) return;
    if (!await File(path).exists()) {
      Log.w('remembered model gone: $path');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your last model is no longer on the phone. Pick one to load.',
            ),
          ),
        );
      }
      return;
    }
    try {
      final gpu = await GpuService.detect();
      final ok = await llm.loadModel(
        path,
        gpuLayers: 0,
        totalRamMb: gpu.totalRamMb,
      );
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not load that model'
                  '${llm.lastLoadError == null ? '' : ': ${llm.lastLoadError}'}',
            ),
          ),
        );
      }
    } catch (e) {
      Log.w('remembered model failed to load: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load your last model.')),
      );
    }
  }

  /// Restart always-listening if the toggle is on, and wire this screen
  /// as the wake-word target while it is alive.
  Future<void> _restoreWakeListening() async {
    final wake = _wake;
    if (wake == null) return;
    wake.onWakeWord = () {
      if (!mounted) return;
      wake.markListening();
      _startVoiceInput();
    };
    final enabled =
        ref.read(settingsProvider)['always_listening'] as bool? ?? false;
    if (!enabled || wake.isRunning) return;
    final problem = await wake.start();
    if (problem != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Always-listening is off: $problem')),
      );
    }
  }

  /// Toggle always-listening from the header WAKE pill. Mirrors the
  /// Settings → Voice switch exactly: flip the setting, start or stop
  /// the wake service, and on a failed start flip the setting back so
  /// the pill never lies. Missing key / keyword file fails here just
  /// as it does on the switch.
  Future<void> _toggleWakeListening() async {
    final wake = _wake;
    final enabled =
        ref.read(settingsProvider)['always_listening'] as bool? ?? false;
    final next = !enabled;
    ref.read(settingsProvider.notifier).updateSetting(
      'always_listening',
      next,
    );
    if (next) {
      final problem = await wake?.start();
      if (problem != null) {
        ref.read(settingsProvider.notifier).updateSetting(
          'always_listening',
          false,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(problem)),
          );
        }
      }
    } else {
      await wake?.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    AssistantLaunch.setListenHandler(null);
    _wake?.onWakeWord = null;
    _flushTimer?.cancel();
    _cloudSub?.cancel();
    if (_cloudCompleter != null && !_cloudCompleter!.isCompleted) {
      _cloudCompleter!.complete();
    }
    _controller.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final settings = ref.watch(settingsProvider);
    final modelPath = settings['model_path'] as String?;
    final hasModel = modelPath != null && modelPath.trim().isNotEmpty;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: hasModel
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.background,
                    AppColors.background.withValues(alpha: 0.95),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.3, 1.0],
                )
              : null,
        ),
        child: Column(
          children: [
            _ChatHeader(
              modelPath: modelPath,
              alwaysListening:
                  settings['always_listening'] as bool? ?? false,
              onToggleWake: _toggleWakeListening,
              onOpenMenu: () => Scaffold.of(context).openDrawer(),
              onManageModels: _showModelSelector,
              onClear: _clearChat,
              onExport: _exportChat,
              onStopSpeaking: () => ref
                  .read(textToSpeechProvider.notifier)
                  .stop(),
            ),

            // Messages list
            Expanded(
              child: messages.isEmpty
                  ? ChatEmptyState(
                      modelLoaded: hasModel,
                      onManageModels: _showModelSelector,
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: messages.length + (_isThinking ? 1 : 0),
                      itemBuilder: (context, index) {
                        // While a reply is generating, index 0 is the live
                        // reply. Before the answer starts — the model is
                        // still inside its <think> block — there is nothing
                        // to show yet, so the thinking spinner stays. Once
                        // answer text arrives it types out live in a normal
                        // assistant bubble: splitThinking strips the
                        // reasoning out, so the thinking never shows even
                        // while it streams. A stable key keeps the tile
                        // (and its enter animation) alive across chunk
                        // rebuilds instead of re-animating on every token.
                        if (index == 0 && _isThinking) {
                          final liveAnswer =
                              splitThinking(_currentResponse).answer;
                          if (liveAnswer.trim().isEmpty) {
                            return const ThinkingBubble();
                          }
                          return ChatMessageTile(
                            key: const ValueKey('live-response'),
                            message: ChatMessage(
                              id: 'live-response',
                              role: 'assistant',
                              content: liveAnswer,
                              timestamp:
                                  DateTime.now().millisecondsSinceEpoch,
                            ),
                          );
                        }
                        // Messages are newest-first, so the bubble at
                        // index 0 shifts every message by one while a
                        // reply is generating.
                        final messageIndex =
                            _isThinking ? index - 1 : index;
                        final message = messages[messageIndex];
                        return FadeSlideIn(
                          // Stagger capped hard: the index runs
                          // newest-first, so without a cap the fifth item
                          // of a long transcript would still be waiting
                          // 500 ms and the hundredth five seconds. Five
                          // steps covers every message that is actually on
                          // screen at insertion time.
                          delay: Duration(
                            milliseconds:
                                (messageIndex > 5 ? 5 : messageIndex) * 50,
                          ),
                          child: ChatMessageTile(message: message),
                        );
                      },
                    ),
            ),

            // Attachment previews
            if (_attachedImages.isNotEmpty || _attachedDocs.isNotEmpty)
              _buildAttachmentStrip(),

            // Composer first, mode + effort switcher below it: the switcher
            // used to sit above the composer; it now lives under the typing
            // box instead. One SafeArea for both, so the bottom system
            // inset is applied once, below the switcher.
            SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChatComposer(
                    controller: _controller,
                    focusNode: _composerFocus,
                    isGenerating: _isThinking,
                    isListening: _isListening,
                    onSend: _sendMessage,
                    onStop: _stopGeneration,
                    onAttachImage: _pickImage,
                    onAttachDocument: _pickDocument,
                    onVoice: _startVoiceInput,
                    onStopVoice: _stopVoiceInput,
                    imageTooltip: 'Attach an image (needs a vision model)',
                    documentTooltip:
                        'Attach a document: ${DocumentService.supportedSummary}',
                  ),
                  _ModeBar(
                    mode: settings['chat_mode'] as String? ?? 'chat',
                    effort: settings['thinking_effort'] as String? ?? 'med',
                    onModeChanged: (mode) => ref
                        .read(settingsProvider.notifier)
                        .updateSetting('chat_mode', mode),
                    onEffortChanged: (effort) => ref
                        .read(settingsProvider.notifier)
                        .updateSetting('thinking_effort', effort),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentStrip() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 76,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final path in _attachedImages)
            Stack(
              children: [
                Container(
                  margin: const EdgeInsets.only(right: 10),
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    image: DecorationImage(
                      image: FileImage(File(path)),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  top: -6,
                  child: IconButton(
                    iconSize: 15,
                    splashRadius: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 22,
                      height: 22,
                    ),
                    tooltip: 'Remove this image',
                    icon: const Icon(Icons.cancel, color: AppColors.danger),
                    onPressed: () =>
                        setState(() => _attachedImages.remove(path)),
                  ),
                ),
              ],
            ),
          for (final doc in _attachedDocs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                avatar: const Icon(
                  Icons.description,
                  size: 16,
                  color: AppColors.accent,
                ),
                label: Text(
                  '${doc.name} (${doc.chunks.length})',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                onDeleted: () => setState(() => _attachedDocs.remove(doc)),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- attachments

  /// Pick an image and queue it for the next turn.
  ///
  /// Vision is only useful with a compatible model attached, so this warns
  /// instead of silently attaching an image that will be ignored.
  Future<void> _pickImage() async {
    try {
      // The picker pauses the activity, which would otherwise re-engage the app
      // lock over it. Tell the gate this pause is expected.
      BiometricGate.suppressReLock();
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        // Downscale before the model sees it: a 12 MP photo is slow to decode
        // and buys nothing over 1024 px for Moondream-class models.
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;

      final llm = ref.read(llmServiceProvider);
      setState(() => _attachedImages.add(file.path));

      if (!llm.isVisionLoaded) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Image attached. No vision model is loaded on this phone — '
              'this turn will use a cloud model if one is set up.',
            ),
          ),
        );
      }
    } catch (e) {
      Log.w('image pick failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open the gallery.')));
    }
  }

  /// Pick and ingest a document, then hand it to the memory store.
  Future<void> _pickDocument() async {
    try {
      // Same reason as the image picker: this pause is expected, not the user
      // leaving the app.
      BiometricGate.suppressReLock();
      final result = await FilePicker.pickFiles(type: FileType.any);
      final path = result.isEmpty ? null : result.first.path;
      if (path == null || !mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      // Captured before the ingest so every exit path can close the spinner.
      // `if (mounted) Navigator.of(context).pop()` skipped the close whenever
      // the user left the screen mid-ingest, leaving a non-dismissible spinner
      // stranded on the navigator they came back to.
      final nav = Navigator.of(context);

      try {
        final doc = await DocumentService.instance.ingest(path);

        if (doc.textLayerMissing) {
          if (nav.canPop()) nav.pop();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'That PDF has no text layer (it looks like a scan). '
                'OCR is not enabled — paste the text instead.',
              ),
            ),
          );
          return;
        }

        // Store chunks with embeddings when the encoder is available, so the
        // document is retrievable by meaning and not only by keyword.
        final db = ref.read(databaseProvider);
        final embed = EmbeddingService.getInstance();
        final id = _uuid.v4();

        await db.insertDocument(
          id: id,
          name: doc.name,
          path: path,
          mime: doc.mimeGuess,
          charCount: doc.charCount,
          chunkCount: doc.chunks.length,
        );

        if (embed.isLoaded && doc.chunks.isNotEmpty) {
          final vectors = <List<double>>[];
          for (final chunk in doc.chunks) {
            vectors.add(await embed.generateEmbedding(chunk));
          }
          await db.insertChunks(
            documentId: id,
            texts: doc.chunks,
            vectors: vectors,
          );
        }

        if (nav.canPop()) nav.pop();
        if (!mounted) return;

        setState(() => _attachedDocs.add(doc));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added "${doc.name}".',
            ),
          ),
        );
      } catch (e) {
        if (nav.canPop()) nav.pop();
        rethrow;
      }
    } catch (e) {
      Log.w('document ingest failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  // ------------------------------------------------------------------- send

  /// Streams one model reply into the bubble, honouring Stop.
  Future<void> _streamReply({
    required String prompt,
    required String? systemPrompt,
    required List<Map<String, String>> history,
    String? imagePath,
  }) async {
    final llmService = ref.read(llmServiceProvider);
    await for (final token in llmService.generateStream(
      prompt: prompt,
      systemPrompt: systemPrompt,
      history: history,
      maxTokens: _responseTokens(),
      imagePath: imagePath,
    )) {
      if (_stopRequested) break;
      _bufferToken(token);
    }
    _flushNow();
  }

  Future<void> _sendMessage([String? text]) async {
    // Only the mic passes text; the composer sends with no argument.
    // This is what gates auto-listen after the reply.
    _voiceExchange = text != null;
    // Refresh location + temperature in the background; the cached line
    // (if any) is what this send's system prompt carries.
    unawaited(_refreshLocationWeather());
    final messageText = text ?? _controller.text.trim();
    final hasImages = _attachedImages.isNotEmpty;
    if (messageText.isEmpty && !hasImages && _attachedDocs.isEmpty) return;

    _controller.clear();

    // Snapshot attachments, then clear so the next turn starts fresh.
    final imagePath = hasImages ? _attachedImages.first : null;
    final docCtx = _attachedDocs.isEmpty
        ? ''
        : '\n\nContext from attached documents:\n'
              '${_attachedDocs.map((d) => '--- ${d.name} ---\n${TextUtils.ellipsize(d.text, 4000)}').join('\n\n')}';

    final display = messageText.isEmpty
        ? (hasImages ? '(image)' : '(document)')
        : messageText;

    setState(() {
      _attachedImages.clear();
      _attachedDocs.clear();
    });

    // Snapshot the conversation BEFORE this message is appended. The old code
    // read it afterwards and then appended the message again, so the model was
    // given the question twice.
    final priorHistory = List<ChatMessage>.from(ref.read(chatMessagesProvider));

    _stopRequested = false;
    _pendingTokens = '';

    // Add user message
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: imagePath != null ? '$display\n[image attached]' : display,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(chatMessagesProvider.notifier).addMessage(userMessage);

    // ---- route this turn ------------------------------------------------
    final llmService = ref.read(llmServiceProvider);
    final settings = ref.read(settingsProvider);
    final router = RouterService.instance;
    // A one-off "send just this one to the cloud" is consumed exactly once, so
    // it applies to this message and not the next. It never overrides private
    // mode — `routeConfigForTurn` guards that.
    final sendToCloudOnce = ref.read(cloudOnceProvider.notifier).consume();

    final decision = router.decide(
      prompt: '$display$docCtx',
      config: routeConfigForTurn(
        mode: '${settings['cloud_mode'] ?? 'auto'}',
        privateMode: settings['private_mode'] as bool? ?? false,
        preferLocalOnMetered: settings['prefer_local_metered'] as bool? ?? true,
        sendToCloudOnce: sendToCloudOnce,
      ),
      hasImages: hasImages,
      localVisionReady: llmService.isVisionLoaded,
      localModelReady: llmService.isLoaded,
    );

    if (decision.isCloud) {
      await _sendViaCloud(decision, '$display$docCtx', imagePath, priorHistory);
      return;
    }

    if (decision.isRefused) {
      // Say why, in the transcript, and stop. Calling a model here would mean
      // returning a confident answer to a question it was never shown.
      Log.w('turn refused: ${decision.reason}');
      await ref
          .read(chatMessagesProvider.notifier)
          .addMessage(
            ChatMessage(
              id: _uuid.v4(),
              role: 'assistant',
              content: decision.reason,
              timestamp: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      // A new message just landed: go to the bottom even if the user was
      // reading earlier messages.
      if (mounted) _scrollToBottom(force: true);
      return;
    }

    if (!llmService.isLoaded) {
      await _showModelNotLoadedDialog();
      return;
    }

    // Process through agent pipeline
    setState(() {
      _isThinking = true;
      _currentResponse = '';
    });

    try {
      // Tools are local-only: the cloud path builds its own request and
      // never parses tool calls, so a tools section there would only make
      // the model print raw JSON.
      final toolsSection =
          await ref.read(toolRegistryProvider).promptSection();
      final request = _buildRequest(
        message: '$display$docCtx',
        priorHistory: priorHistory,
        toolsSection: toolsSection,
      );

      // Streaming response
      await _streamReply(
        prompt: request.prompt,
        systemPrompt: request.systemPrompt,
        history: request.history,
        imagePath: imagePath,
      );

      // One tool round per turn: if the reply was a tool call, run it and
      // generate a brief answer from the result. The raw JSON never reaches
      // the transcript — the follow-up answer replaces it.
      final call = parseToolCall(_currentResponse);
      if (call != null && !_stopRequested) {
        final registry = ref.read(toolRegistryProvider);
        final result = await registry.executeTool(
          toolName: call.tool,
          params: call.params,
        );
        // Clear the tool JSON out of the bubble before the answer streams.
        _pendingTokens = '';
        _flushTimer?.cancel();
        _flushTimer = null;
        if (mounted) {
          setState(() => _currentResponse = '');
        }
        final followUp = _buildRequest(
          message:
              'The tool "${call.tool}" returned:\n${TextUtils.ellipsize(result.toJson(), 2000)}\n'
              'Answer the user briefly based on this result. Do not call another tool — answer directly in plain text.',
          priorHistory: [...priorHistory, userMessage],
          // No tools section: this turn answers, it does not act.
        );
        await _streamReply(
          prompt: followUp.prompt,
          systemPrompt: followUp.systemPrompt,
          history: followUp.history,
        );
      }

      _flushNow();
      await _finishAssistantMessage();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isThinking = false;
          _currentResponse = '';
        });
        // The answer has landed: return to the bottom even if the user was
        // reading earlier messages while it generated.
        _scrollToBottom(force: true);
      }
    }
  }

  /// Send the turn to the selected cloud provider instead of the local model.
  Future<void> _sendViaCloud(
    RouteDecision decision,
    String prompt,
    String? imagePath,
    List<ChatMessage> priorHistory,
  ) async {
    final provider = decision.provider;
    if (provider == null) {
      await _showModelNotLoadedDialog();
      return;
    }

    setState(() {
      _isThinking = true;
      _currentResponse = '';
    });

    try {
      // Same newest-first, budgeted selection as the local path. This used to
      // be `history.take(12)`, i.e. the twelve OLDEST messages.
      final request = _buildRequest(
        message: prompt,
        priorHistory: priorHistory,
      );
      final messages = <Map<String, String>>[
        if (request.systemPrompt != null)
          {'role': 'system', 'content': request.systemPrompt!},
        ...request.history,
        {'role': 'user', 'content': request.prompt},
      ];

      final imagesB64 = <String>[];
      if (imagePath != null) {
        try {
          imagesB64.add(base64Encode(await File(imagePath).readAsBytes()));
        } catch (e) {
          Log.w('could not read image for cloud: $e');
        }
      }

      final cloud = ref.read(cloudServiceProvider);

      // Listen through a subscription rather than `await for` so Stop has
      // something it can actually cancel.
      final completer = Completer<void>();
      _cloudCompleter = completer;
      _cloudSub = cloud
          .stream(
            provider: provider,
            turn: CloudTurn(
              modelId: decision.modelId,
              messages: messages,
              imageBase64: imagesB64,
            ),
          )
          .listen(
            (token) {
              if (_stopRequested) return;
              _bufferToken(token);
            },
            onError: (Object e) {
              if (!completer.isCompleted) completer.completeError(e);
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          );

      try {
        await completer.future;
      } finally {
        await _cloudSub?.cancel();
        _cloudSub = null;
        _cloudCompleter = null;
      }

      _flushNow();
      await _finishAssistantMessage();
    } catch (e) {
      Log.w('cloud turn failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isThinking = false;
          _currentResponse = '';
        });
        // The answer has landed: return to the bottom even if the user was
        // reading earlier messages while it generated.
        _scrollToBottom(force: true);
      }
    }
  }

  /// Persist the assistant reply, then speak it if TTS is on.
  Future<void> _finishAssistantMessage() async {
    // Strip first: a reply that was nothing but special tokens must
    // still hit the empty guard below instead of persisting as blank.
    _currentResponse = _stripSpecialTokens(_currentResponse);
    if (_currentResponse.trim().isEmpty) return;

    // A stopped reply is kept and labelled rather than discarded: half a useful
    // answer is worth more than none, but the history should say what happened.
    final content = _stopRequested
        ? '$_currentResponse\n\n_(stopped)_'
        : _currentResponse;

    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(chatMessagesProvider.notifier).addMessage(assistantMessage);

    // Speaking a half-finished sentence is worse than not speaking it.
    if (_stopRequested) return;

    final ttsEnabled =
        ref.read(settingsProvider)['tts_enabled'] as bool? ?? true;
    if (ttsEnabled) {
      // Read the answer, not the reasoning: the `<think>` block is for the
      // eye, not the ear. Falls back to the whole reply when the answer is
      // empty (a reply that was all thinking).
      final answer = splitThinking(_currentResponse).answer;
      await ref
          .read(textToSpeechProvider.notifier)
          .speak(answer.isNotEmpty ? answer : _currentResponse);
    }

    // Cypher voice conversation: after a spoken reply, listen again so
    // the user can keep talking without tapping. Only after a voice
    // exchange — never after typed messages — and only while results
    // keep coming back; silence ends the loop in _startVoiceInput.
    if (_voiceExchange && mounted) {
      _startVoiceInput();
    } else {
      _wake?.markIdle();
    }
  }

  Future<void> _exportChat() async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.isEmpty) return;

    final buf = StringBuffer('# Clawzilla chat export\n\n');
    for (final m in messages) {
      buf.writeln('**${m.role}** (${m.timestamp})');
      buf.writeln(m.content);
      buf.writeln();
    }

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/clawzilla-chat.md');
      await file.writeAsString(buf.toString());
      await Share.shareXFiles([XFile(file.path)], text: 'Clawzilla chat');
    } catch (e) {
      Log.w('export failed: $e');
    }
  }

  /// Tokens reserved for the reply when budgeting history.
  ///
  /// Without this the transcript can fill the whole context window and the
  /// model has no room left to answer. Driven by the thinking-effort
  /// switch: Low keeps replies short, High lets them run longer. This is
  /// a reply-length hint, not a true reasoning budget — a local model has
  /// no reasoning knob to turn.
  int _responseTokens() {
    return switch (ref.read(settingsProvider)['thinking_effort']) {
      'low' => 256,
      'high' => 1024,
      _ => 512,
    };
  }

  /// The mode's instruction, added to the system prompt alongside the
  /// personality. Chat adds nothing — it is the plain default, which is
  /// what keeps the wire-format test green for the common case.
  String? _modeInstruction(String mode) {
    return switch (mode) {
      'plan' =>
        'Before answering, make a short plan first, then follow it step '
            'by step. If the request needs several steps, lay out the '
            'steps, then do them in order.',
      'code' =>
        'Answer as a coding helper: give working code first, then a short '
            'explanation. Keep the code complete and ready to paste.',
      _ => null,
    };
  }

  /// Refreshes the location + temperature line in the background. The
  /// service caches for 10 minutes, so this is cheap to call on every
  /// send; a null result (no permission, no fresh fix, no network) just
  /// leaves the prompt with the "unknown" guard line below.
  /// Fire-and-forget — it never blocks sending.
  Future<void> _refreshLocationWeather() async {
    final line = await _locationWeather.getLine();
    if (mounted && line != _locationLine) {
      setState(() => _locationLine = line);
    }
  }

  /// The current date and time, so the model always knows what day it is.
  /// A local model has no clock; without this it guesses (and hallucinates)
  /// when asked the date. Built by hand — no intl dependency — from the
  /// phone's own clock, so it is always the user's local date and time.
  String _nowLine() {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final now = DateTime.now();
    final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final ampm = now.hour < 12 ? 'AM' : 'PM';
    final minute = now.minute.toString().padLeft(2, '0');
    return 'Today is ${weekdays[now.weekday - 1]}, '
        '${months[now.month - 1]} ${now.day}, ${now.year}. '
        'The current time is $hour12:$minute $ampm.';
  }

  /// Builds the system prompt, the question, and the history to send.
  ///
  /// [priorHistory] must be the conversation **before** the current message.
  /// The old code read the provider *after* appending the user message and then
  /// appended it to the prompt again, so the model saw the question twice.
  ///
  /// Selection is newest-first under a token budget (see [buildRecentTurns]).
  /// The old `history.take(10)` took the ten OLDEST messages of a chronological
  /// list, so a long conversation sent the opening turns and nothing recent.
  ///
  /// The return is split into the parts `LlmService.generateStream` expects,
  /// which is what keeps `test/llm_wire_format_test.dart` green.
  ({String prompt, String? systemPrompt, List<Map<String, String>> history})
  _buildRequest({
    required String message,
    required List<ChatMessage> priorHistory,
    String? toolsSection,
  }) {
    final settings = ref.read(settingsProvider);
    final personality = settings['personality'] as String?;
    final nCtx = ref.read(llmServiceProvider).contextSize;

    // The system prompt is the date and time first — the model has no
    // clock of its own — then where the user is and the temperature,
    // then the personality plus the mode's instruction, when the mode
    // has one. Chat mode adds nothing. The tools section goes last, and
    // only on the local path: the cloud path never parses tool calls.
    final modeInstruction =
        _modeInstruction(settings['chat_mode'] as String? ?? 'chat');
    final systemParts = <String>[
      _nowLine(),
      if (_locationLine != null) _locationLine!,
      // When the location line is missing, say so outright. A small model
      // asked "where am I?" with no location in the prompt used to answer
      // with the time from the line above — or invent a temperature. An
      // honest "unknown" beats a confident wrong answer.
      if (_locationLine == null)
        'LOCATION: unknown — if asked where the user is or what the '
        'temperature is, say you do not know; do not guess.',
      if (personality != null && personality.trim().isNotEmpty) personality,
      if (modeInstruction != null) modeInstruction,
      if (toolsSection != null && toolsSection.trim().isNotEmpty)
        toolsSection,
    ];
    final systemPromptText =
        systemParts.isEmpty ? null : systemParts.join('\n\n');

    final selection = buildRecentTurns(
      history: [
        for (final m in priorHistory) Turn(m.role, m.content),
        Turn('user', message),
      ],
      tokenBudget: nCtx,
      systemPrompt: systemPromptText,
      reserveForResponse: _responseTokens(),
    );

    final turns = selection.turns;
    if (turns.isEmpty) {
      return (prompt: message, systemPrompt: null, history: const []);
    }

    final hasSystem = turns.first.role == 'system';
    final systemPrompt = hasSystem ? turns.first.content : null;
    final prompt = turns.last.content;

    // Everything between the system prompt and the question is history.
    final body = turns.sublist(hasSystem ? 1 : 0, turns.length - 1);

    return (
      prompt: prompt,
      systemPrompt: systemPrompt,
      history: [
        for (final t in body) {'role': t.role, 'content': t.content},
      ],
    );
  }

  /// Buffers a streamed token and schedules one UI update.
  ///
  /// `setState` used to run per token, rebuilding this whole screen hundreds of
  /// times a second for no visible benefit.
  void _bufferToken(String token) {
    _pendingTokens += token;
    // A tool call is not an answer: while the reply looks like one (a
    // ```json fence or a bare object at the start), keep its tokens out
    // of the bubble. If the turn ends with no tool call, the final flush
    // still shows the whole reply, so nothing is ever lost.
    final soFar = (_currentResponse + _pendingTokens).trimLeft();
    if (soFar.startsWith('```json') ||
        soFar.startsWith('```tool') ||
        soFar.startsWith('{')) {
      _flushTimer?.cancel();
      _flushTimer = null;
      return;
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 50), _flushNow);
  }

  void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingTokens.isEmpty || !mounted) return;
    final chunk = _pendingTokens;
    _pendingTokens = '';
    setState(() => _currentResponse += chunk);
    _scrollToBottom();
  }

  /// Stops generation, keeping whatever text already arrived.
  ///
  /// There was no way to stop a reply at all before this: the only cancel icon
  /// in the composer removed an attached image.
  Future<void> _stopGeneration() async {
    if (!_isThinking || _stopRequested) return;
    _stopRequested = true;

    // The cloud path is cancelled through its subscription; the local path
    // through the service, which closes the stream the loop is awaiting.
    await _cloudSub?.cancel();
    _cloudSub = null;
    // Cancelling the subscription does not complete the completer that
    // `_sendViaCloud` is awaiting, so release it here — otherwise the cloud
    // turn hangs at `await completer.future` and the Stop button sticks.
    if (_cloudCompleter != null && !_cloudCompleter!.isCompleted) {
      _cloudCompleter!.complete();
    }
    try {
      await ref.read(llmServiceProvider).stop();
    } catch (e) {
      Log.w('stop failed: $e');
    }
    _flushNow();
  }

  void _clearChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Chat'),
        content: const Text('Are you sure you want to clear all messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref.read(chatMessagesProvider.notifier).clearChat();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showModelSelector() {
    showDialog(
      context: context,
      builder: (context) => const ModelSelectorDialog(),
    );
  }

  Future<void> _showModelNotLoadedDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model Not Loaded'),
        content: const Text(
          'Please download and load a model first. Go to Settings > Models.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _startVoiceInput() async {
    // One listen at a time: the mic tap, the wake word, the side button
    // and the auto-listen after a reply can all fire while a listen is
    // already in flight, and a second listen orphaned the first one's
    // result — the mic stayed lit until its timeout.
    if (_isListening) return;
    final speechNotifier = ref.read(speechToTextProvider.notifier);
    final isAvailable = ref.read(speechToTextProvider);

    if (!isAvailable) {
      await speechNotifier.init();
      if (!ref.read(speechToTextProvider)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Speech recognition isn't available on this phone.",
              ),
            ),
          );
        }
        _wake?.markIdle();
        return;
      }
    }

    // Light the mic up before listening starts, so the user can see the
    // app heard the tap even while the recogniser warms up.
    if (_isListening) return; // Lost a race with another starter.
    final generation = ++_listenGeneration;
    _voiceStopRequested = false;
    if (mounted) setState(() => _isListening = true);
    final speech = ref.read(speechToTextProvider.notifier);
    // The wake detector holds the mic while it listens, and speech
    // recognition needs the mic to itself — if the detector is running,
    // the recogniser hears nothing and every listen ends with "Didn't
    // catch that". Pause the detector for the listen, then put it back
    // if it was on.
    final wasWakeRunning = _wake?.isRunning ?? false;
    if (wasWakeRunning) await _wake?.stop();
    String? result;
    try {
      result = await speech.listenOnce();
    } catch (e) {
      // A failed listen is an empty listen as far as the user is
      // concerned: nothing was heard, so the empty path below reports it.
      Log.w('listen failed: $e');
      result = null;
    } finally {
      // Only this listen may darken the mic: a newer listen may already
      // be running (tap stop, tap mic again), and clearing here would
      // leave it dark while it listens.
      if (mounted && generation == _listenGeneration) {
        setState(() => _isListening = false);
      }
      // Put wake listening back if it was on. Fire-and-forget: the mic
      // result is what matters here, and the restart must not stall it.
      if (wasWakeRunning) unawaited(_wake?.start());
    }

    if (result != null && result.isNotEmpty && mounted) {
      _sendMessage(result);
    } else if (mounted && !_voiceStopRequested) {
      // The listen ended with nothing heard. Say so instead of going
      // quiet — silence used to look exactly like a broken mic.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Didn't catch that — try again.")),
      );
      _wake?.markIdle();
    } else {
      _wake?.markIdle();
    }
    _voiceStopRequested = false;
  }

  /// Stop the current listen, from a tap on the lit mic button. The mic
  /// goes dark on the tap itself: the engine can take a moment to report
  /// that it stopped, and waiting on it is what left the button looking
  /// stuck. The in-flight `listenOnce` resolves with whatever was heard
  /// (or empty), and [_voiceStopRequested] keeps an empty one from
  /// showing "Didn't catch that".
  Future<void> _stopVoiceInput() async {
    if (!_isListening) return;
    _voiceStopRequested = true;
    if (mounted) setState(() => _isListening = false);
    try {
      await ref.read(speechToTextProvider.notifier).stopListening();
    } catch (e) {
      Log.w('stop listening failed: $e');
    }
  }

  void _scrollToBottom({bool force = false}) {
    // Offset 0 is the latest end of the reversed list (the bottom).
    // Unless forced, stand down while the user is reading earlier messages
    // — the streaming flush used to yank the list back here every 50 ms.
    if (!force && _userScrolledAway) return;
    if (force) _userScrolledAway = false;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_scrollController.hasClients) return;
      if (!force && _userScrolledAway) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }
}

/// The header above the transcript.
///
/// App identity on the left, stop-voice and the overflow menu on the right.
/// The live model used to sit here as a chip; it was removed Nov 12, 2026
/// because it crowded the header and pushed the stop-voice button
/// off-screen. The weights line below still shows which model is loaded,
/// and "Change model" still lives in the overflow menu.
class _ChatHeader extends StatefulWidget {
  const _ChatHeader({
    required this.modelPath,
    required this.alwaysListening,
    required this.onToggleWake,
    required this.onOpenMenu,
    required this.onManageModels,
    required this.onClear,
    required this.onExport,
    required this.onStopSpeaking,
  });

  final String? modelPath;

  /// Drives the WAKE: ON/OFF pill. Read from settings by the parent so the
  /// header itself stays a plain StatefulWidget.
  final bool alwaysListening;

  /// Tapping the WAKE pill toggles always-listening (same toggle as the
  /// Settings → Voice switch).
  final VoidCallback onToggleWake;

  /// Opens the navigation drawer (the slide-out panel that replaced the
  /// bottom bar).
  final VoidCallback onOpenMenu;

  final VoidCallback onManageModels;
  final VoidCallback onClear;
  final VoidCallback onExport;

  /// Cuts off the voice reading a reply aloud, right now. The button is
  /// always there so it can be hit the moment the voice is unwanted —
  /// stopping an idle engine is a harmless no-op.
  final VoidCallback onStopSpeaking;

  @override
  State<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends State<_ChatHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = widget.modelPath;
    final loaded = path != null && path.trim().isNotEmpty;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          ),
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, -0.15),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _controller,
                    curve: const Interval(0.0, 0.7, curve: Curves.easeOutCubic),
                  ),
                ),
            child: Container(
              color: AppColors.background,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  // Clawziod look: the header is three rows — the title row,
                  // then the weights line, then the WAKE pill.
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                      // Menu button for the navigation drawer (the
                      // slide-out panel that replaced the bottom bar).
                      IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: 'Menu',
                        iconSize: 22,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        color: scheme.onSurfaceVariant,
                        onPressed: widget.onOpenMenu,
                      ),
                      const SizedBox(width: 2),
                      ScaleTransition(
                        scale: CurvedAnimation(
                          parent: _controller,
                          curve: const Interval(
                            0.2,
                            0.8,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        // Clawziod look: the Matrix hand mark, not the old
                        // head glyph. Same asset as the splash and settings
                        // header, so the brand is one image everywhere.
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.brand.withValues(alpha: 0.4),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.brand.withValues(alpha: 0.2),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images/clawzilla-mark.png',
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FadeTransition(
                        opacity: CurvedAnimation(
                          parent: _controller,
                          curve: const Interval(
                            0.3,
                            1.0,
                            curve: Curves.easeOut,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'CLAWZILLA',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              'LOCAL AGENT',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    letterSpacing: 2.0,
                                    color: scheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      // No model chip here any more (Nov 12, 2026 — Aaron
                      // asked for it gone): it crowded the header and pushed
                      // the stop-voice button off-screen. The weights line
                      // below still shows which model is loaded.
                      // Stop voice: cuts off the voice reading a reply
                      // aloud, right now (Nov 11, 2026 — Aaron asked for a
                      // way to cut it off mid-speech, e.g. while listening
                      // to something else). It sits in the header so it is
                      // always one tap away, and stopping an idle engine
                      // is a harmless no-op. Big and filled since Nov 12,
                      // 2026: the small outlined grey icon could barely be
                      // seen or tapped.
                      IconButton(
                        icon: const Icon(Icons.volume_off),
                        tooltip: 'Stop voice',
                        iconSize: 28,
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.errorContainer,
                          foregroundColor: scheme.onErrorContainer,
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: widget.onStopSpeaking,
                      ),
                      const SizedBox(width: 4),
                      // One overflow menu for the rest: Change model,
                      // Clear chat, Export. Clear used to have its own
                      // button in the header; it now lives here so the
                      // header stays quiet.
                      ScaleTransition(
                        scale: CurvedAnimation(
                          parent: _controller,
                          curve: const Interval(
                            0.6,
                            1.0,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        child: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'model') widget.onManageModels();
                            if (value == 'clear') widget.onClear();
                            if (value == 'export') widget.onExport();
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'model',
                              child: Text('Change model'),
                            ),
                            PopupMenuItem(
                              value: 'clear',
                              child: Text('Clear chat'),
                            ),
                            PopupMenuItem(
                              value: 'export',
                              child: Text('Export chat'),
                            ),
                          ],
                          tooltip: 'More',
                          iconSize: 20,
                          icon: Icon(
                            Icons.more_vert,
                            color: scheme.onSurfaceVariant,
                          ),
                          padding: EdgeInsets.zero,
                          // No `constraints` here on purpose: on PopupMenuButton that
                          // parameter constrains the dropdown menu, not the button, and
                          // a tight width would collapse the menu itself.
                        ),
                      ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Weights line: what is actually loaded, on its own
                      // full-width row so it is never squeezed to "WEIG…".
                      // Full friendly name here — this is now the only
                      // place the header shows the loaded model, since the
                      // chip is gone.
                      Text(
                        loaded
                            ? 'WEIGHTS: ${ModelPreflight.friendlyName(path.split('/').last)}'
                            : 'WEIGHTS: NO MODEL LOADED',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 4),
                      // Pills: wake state on a third row in a Wrap so it
                      // flows instead of squeezing. The AIR-GAP badge is
                      // gone — it was a label, not a control, and the app
                      // already runs local inference by default.
                      Wrap(
                        spacing: 6,
                        children: [
                          _HeaderPill(
                            label: widget.alwaysListening
                                ? 'WAKE: ON'
                                : 'WAKE: OFF',
                            active: widget.alwaysListening,
                            onTap: widget.onToggleWake,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small bordered pill for the chat header's third row.
///
/// Reports a real state (wake listening on/off). With an [onTap] it is a
/// control — tapping it toggles that state; without one it is display only.
class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.label,
    this.icon,
    this.active = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;

  /// Whether the pill reads as "on": brand tint when true, muted when false.
  final bool active;

  /// Tap action, if any. When null the pill renders exactly as before.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = active
        ? AppColors.brand
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final pill = Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: tint.withValues(alpha: 0.45)),
        color: active
            ? AppColors.brand.withValues(alpha: 0.12)
            : Colors.transparent,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: tint),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: tint,
            ),
          ),
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return pill;
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: 'Tap to turn always-listening on or off',
        child: pill,
      ),
    );
  }
}

/// Models sheet.
///
/// Shows what is **actually in memory** next to what is **selected**. Those two
/// drifting apart is exactly how a downloaded vision model ends up never being
/// used: the user picks it, never re-taps Load, and every later image is
/// silently discarded.
class ModelSelectorDialog extends ConsumerWidget {
  const ModelSelectorDialog({super.key});

  /// One file pick at a time across every showing of this dialog (see
  /// [_loadModelFromStorage]).
  static bool _isPickingFile = false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('Models'),
      content: _ModelPickerBody(
        onLoadFile: (path) => _loadModelFile(context, ref, path),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => _loadModelFromStorage(context, ref),
                child: const Text('From storage'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () => _loadSelectedModels(context, ref),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Load'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Load the models the user selected in Settings -> Models.
  ///
  /// Downloading lives in the Models screen; this binds what is already on disk
  /// into the runtime: the chat model first, then the vision model if
  /// one is selected, then the memory search model.
  Future<void> _loadSelectedModels(BuildContext context, WidgetRef ref) async {
    final manager = ModelManager.getInstance();
    final llmService = ref.read(llmServiceProvider);

    final chat = await manager.activeLlm();
    if (!await manager.isInstalled(chat)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No chat model downloaded yet. '
              'Open Settings → Models and pick one.',
            ),
          ),
        );
      }
      return;
    }

    // Architecture check: a vision projector must match the chat model's arch.
    // Qwen3.5 carries vision in its own architecture (qwen35), so if the
    // selected vision model has an llmArch, the chat model must share it — or
    // we refuse to load and tell the user what to do instead of handing the
    // projector to the wrong backbone.
    //
    // Every refusal below has to happen **before** the progress dialog opens.
    // It used to open first, and each guard `return`ed with the dialog still
    // up: a `barrierDismissible: false` spinner that cannot be tapped away, so
    // a mismatched pairing left the app frozen with no way out short of
    // force-closing. That is the "I tap Load over and over and it never
    // loads" report — the load never started, but the screen looked busy.
    var vision = await manager.activeVision();
    String? visionNote;
    if (vision != null && chat.id != vision.id) {
      final chatArch = chat.llmArch;
      final visionArch = vision.llmArch;
      if (chatArch != null && visionArch != null && chatArch != visionArch) {
        visionNote =
            'Pictures off: ${vision.displayName} does not fit '
            '${chat.displayName}.';
        vision = null;
      }
    }

    // Everything that can refuse has now refused. Only the genuinely slow work
    // (reading a multi-hundred-megabyte GGUF into the native runtime) happens
    // behind the spinner, so the dialog can no longer outlive its own guard.
    //
    // The navigator is captured *before* the dialog opens and used to close it
    // afterwards. Reaching for `Navigator.of(context)` at the end instead means
    // an unmounted context (rotate the phone mid-load, or leave the screen)
    // skips the pop and strands a spinner nobody can dismiss.
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    var ok = false;
    var message = 'Could not load that model';

    try {
      // Safe loader (Clawzilla v1): CPU by default. An explicit GPU
      // choice is honoured only after a CPU load has succeeded once;
      // until then the request is deferred to CPU and the message says so.
      var layers = await GpuService.layersForMode(
        '${ref.read(settingsProvider)['gpu_offload'] ?? 'auto'}',
      );
      final cpuSucceeded = ref.read(settingsProvider)['cpu_load_succeeded'];
      final gpuDeferred =
          layers > 0 && cpuSucceeded != true && cpuSucceeded != 'true';
      if (gpuDeferred) {
        layers = 0;
      }
      // Read thread count from settings; default to 4 if missing.
      final threads =
          int.tryParse('${ref.read(settingsProvider)['cpu_threads']}') ?? 4;
      llmService.setThreads(threads);
      ok = await llmService.loadModel(
        await manager.weightPath(chat),
        gpuLayers: layers,
        totalRamMb: (await GpuService.detect()).totalRamMb,
      );

      // Vision is optional — a missing projector must not fail the chat model.
      var visionAttached = false;
      if (ok && vision != null) {
        final projector = await manager.projectorPath(vision);
        if (projector != null) {
          visionAttached = await llmService.loadVision(projector);
          if (!visionAttached) {
            message =
                '${chat.displayName} loaded, but it cannot see pictures yet.'
                '${llmService.lastVisionError == null ? '' : ' ${llmService.lastVisionError}'}';
          }
        } else {
          message =
              '${chat.displayName} loaded, but its picture file is '
              'missing. Download ${vision.displayName} again in Settings → Models.';
        }
      }

      // Embeddings power Memory search; silent failure is fine, the app
      // simply stores memories without retrieving them.
      final embed = await manager.activeEmbedding();
      if (embed != null) {
        final embedService = EmbeddingService.getInstance();
        if (!embedService.isLoaded) {
          await embedService.loadModel(await manager.weightPath(embed));
        }
      }

      // Only advertise a model as "in memory" when it actually got there.
      // Writing this after a failed load is what made the picker claim a model
      // was loaded while the runtime held nothing.
      if (ok && context.mounted) {
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('model_path', await manager.weightPath(chat));
        if (llmService.activeBackend == 'cpu') {
          await ref
              .read(settingsProvider.notifier)
              .updateSetting('cpu_load_succeeded', 'true');
        }
      }
      if (ok && message == 'Could not load that model') {
        message =
            '${chat.displayName} ready'
            '${visionAttached ? ' · can see pictures' : ''}'
            '${visionNote == null ? '' : ' · $visionNote'}';
      } else if (!ok && message == 'Could not load that model') {
        // The native error is the only diagnostic that distinguishes "out of
        // RAM" from "corrupt file" from "GPU driver refused" — show it.
        message =
            '${chat.displayName} could not load. '
            '${llmService.lastLoadError ?? 'Free up space and try again.'}';
      }
      if (ok && gpuDeferred) {
        message += ' · graphics will stay off until a plain load works';
      }
    } catch (e) {
      ok = false;
      Log.w('load selected models failed: $e');
      message = 'Could not load that model.';
    }

    // Close the spinner through the captured navigator. Guarded because the
    // route may already be gone if something popped it for us, and popping
    // twice throws.
    if (navigator.canPop()) navigator.pop();
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadModelFromStorage(
    BuildContext context,
    WidgetRef ref,
  ) async {
    // One file pick at a time: the file picker throws `already_active` if a
    // second pick starts while one is still open (e.g. a double-tap on
    // "From storage"), and that error hides the first pick's result.
    if (_isPickingFile) {
      // A pick is already running. Say so instead of silently ignoring the
      // tap — a big model file takes a while to copy, and silence reads as
      // a dead button.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still working on the last file — give it a moment.'),
          ),
        );
      }
      return;
    }
    _isPickingFile = true;
    // Pick any model file from the device and bind it directly — useful
    // for models the catalog does not know about.
    //
    // The spinner goes up BEFORE the pick, not after it: the file picker
    // copies the whole file into the app cache before it answers, and a
    // 2 GB model takes a while to copy. Without this the screen looks dead
    // between picking the file and the load starting, and a second tap
    // lands on a pick that is still running.
    //
    // The navigator is captured before the first await, and `closeSpinner`
    // pops through it exactly once (`spinnerUp`): the inner catch pops and
    // rethrows, and the outer catch would otherwise pop the model picker
    // dialog underneath.
    final nav = Navigator.of(context);
    var spinnerUp = true;
    void closeSpinner() {
      if (!spinnerUp) return;
      spinnerUp = false;
      if (nav.canPop()) nav.pop();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Getting the file ready — a big model can take a minute.'),
          ],
        ),
      ),
    );

    try {
      // Same reason as the image picker: this pause is expected, not the user
      // leaving the app.
      BiometricGate.suppressReLock();
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result.isEmpty || !context.mounted) {
        closeSpinner();
        return;
      }
      final picked = result.first;

      if (!picked.name.toLowerCase().endsWith('.gguf')) {
        closeSpinner();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That is not a model file. Pick a file ending in .gguf.',
            ),
          ),
        );
        return;
      }

      try {
        // Resolve a loadable path. Some pickers hand back no direct
        // filesystem path (cloud files, some Downloads entries); those
        // used to fail silently here. Stream-copy such a file into app
        // storage in chunks instead of loading it into memory at once.
        // file_picker v13 removed withReadStream/readStream; the current
        // API is PlatformFile.readAsByteStream().
        String loadPath;
        if (picked.path != null) {
          loadPath = picked.path!;
        } else {
          final docs = await getApplicationDocumentsDirectory();
          final dir = Directory('${docs.path}/imported');
          await dir.create(recursive: true);
          final copy = File('${dir.path}/${picked.name}');
          final sink = copy.openWrite();
          try {
            await sink.addStream(picked.readAsByteStream());
          } finally {
            await sink.close();
          }
          loadPath = copy.path;
        }

        // Safe loader (Clawzilla v1): storage loads get the same
        // pre-flight checks as catalog loads, on CPU by default.
        final gpu = await GpuService.detect();
        final llm = ref.read(llmServiceProvider);
        final ok = await llm.loadModel(
          loadPath,
          gpuLayers: 0,
          totalRamMb: gpu.totalRamMb,
        );
        closeSpinner();
        if (!context.mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Loaded ${ModelPreflight.friendlyName(loadPath.split('/').last)}'
                  : 'Could not load that model'
                      '${llm.lastLoadError == null ? '' : ': ${llm.lastLoadError}'}',
            ),
          ),
        );
        // Keep model_path so the "Loaded model" card shows the file name
        // instead of "Nothing loaded", and so the model is remembered and
        // reloaded on the next launch. Only on success: a failed load
        // must not overwrite the saved model. active_llm_id stays
        // cleared — no catalog model is selected.
        if (ok && context.mounted) {
          await ref
              .read(settingsProvider.notifier)
              .updateSetting('model_path', loadPath);
          await ref
              .read(settingsProvider.notifier)
              .updateSetting('active_llm_id', null);
          // The file earns a slot in "My models" so Aaron can switch back
          // to it from the picker instead of picking it from storage again.
          await StorageModelsStore.instance.add(loadPath);
        }
      } catch (e) {
        closeSpinner();
        rethrow;
      }
    } catch (e) {
      closeSpinner();
      Log.w('load from storage failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load that file: $e')),
      );
    } finally {
      _isPickingFile = false;
    }
  }

  /// Load a model file that already has a slot (a "My models" row tap).
  ///
  /// Same safe load as [_loadModelFromStorage] but with a known path, so
  /// there is no pick and no copy — just the spinner, the load, and the
  /// result. On success the file becomes the current model; on failure
  /// the reason is shown, and a file that is gone loses its slot.
  Future<void> _loadModelFile(
    BuildContext context,
    WidgetRef ref,
    String loadPath,
  ) async {
    final nav = Navigator.of(context);
    var spinnerUp = true;
    void closeSpinner() {
      if (!spinnerUp) return;
      spinnerUp = false;
      if (nav.canPop()) nav.pop();
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // A slot whose file is gone is not an error to load — it is a slot
      // to forget.
      if (!File(loadPath).existsSync()) {
        await StorageModelsStore.instance.remove(loadPath);
        closeSpinner();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That model file is gone — pick it again.'),
          ),
        );
        return;
      }

      final gpu = await GpuService.detect();
      final llm = ref.read(llmServiceProvider);
      final ok = await llm.loadModel(
        loadPath,
        gpuLayers: 0,
        totalRamMb: gpu.totalRamMb,
      );
      closeSpinner();
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Loaded ${ModelPreflight.friendlyName(loadPath.split('/').last)}'
                : 'Could not load that model'
                    '${llm.lastLoadError == null ? '' : ': ${llm.lastLoadError}'}',
          ),
        ),
      );
      if (ok && context.mounted) {
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('model_path', loadPath);
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('active_llm_id', null);
        await StorageModelsStore.instance.add(loadPath);
      }
    } catch (e) {
      closeSpinner();
      Log.w('load model file failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load that file: $e')),
      );
    }
  }
}

/// The picker inside [ModelSelectorDialog].
///
/// Watches the live selection *and* the live "what is in memory" setting, so the
/// two can be compared on screen. Selecting a model here only changes what will
/// be loaded — it does not hot-swap the runtime — which is precisely why the
/// mismatch warning matters.
class _ModelPickerBody extends ConsumerStatefulWidget {
  const _ModelPickerBody({required this.onLoadFile});

  /// Load a model file that already has a slot (a "My models" row tap).
  /// Passed down from [ModelSelectorDialog], which owns the load.
  final Future<void> Function(String path) onLoadFile;

  @override
  ConsumerState<_ModelPickerBody> createState() => _ModelPickerBodyState();
}

/// Status a model row can be in, driving its badge colour and icon.
enum _ModelStatus {
  /// Downloaded and currently bound in the native runtime.
  loaded,

  /// Downloaded and user-selected but not yet loaded into the runtime.
  selectedPending,

  /// Downloaded but not selected.
  installed,

  /// Not downloaded.
  notInstalled,
}

class _ModelPickerBodyState extends ConsumerState<_ModelPickerBody> {
  final ModelManager _manager = ModelManager.getInstance();

  String? _llmId;
  String? _visionId;
  String? _embeddingId;

  /// modelId -> whether it is fully on disk. Cached so the FutureBuilder does
  /// not re-probe the filesystem on every rebuild, and so a row for a model
  /// the user just downloaded inside this session flips without a full reload.
  final Map<String, bool> _installed = {};

  /// True while [_loadInstalled] is running so the UI can show a loading indicator.
  bool _loading = true;

  /// Models Aaron loaded from storage, most recently loaded first. These
  /// are his slots — blank until he fills them by loading a file, and
  /// tapped to switch between them. Read from the store, never from the
  /// catalog.
  List<String> _storageModels = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadInstalled();
    _loadStorageModels();
    // A storage load writes `model_path` when it finishes; the slot for
    // that file has to appear without closing and reopening the dialog.
    ref.listen(settingsProvider, (previous, next) {
      final prevPath = previous?['model_path'] as String?;
      final nextPath = next['model_path'] as String?;
      if (prevPath != nextPath) _loadStorageModels();
    });
  }

  /// Read the slots, dropping any whose file is gone so the list only
  /// ever shows models that can actually load.
  Future<void> _loadStorageModels() async {
    final stored = await StorageModelsStore.instance.entries();
    final alive = stored.where((p) => File(p).existsSync()).toList();
    if (alive.length != stored.length) {
      for (final p in stored) {
        if (!alive.contains(p)) {
          await StorageModelsStore.instance.remove(p);
        }
      }
    }
    if (!mounted) return;
    setState(() => _storageModels = alive);
  }

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MB';
    if (b <= 0) return '0 MB';
    return '${(b / (1 << 10)).round()} KB';
  }

  Future<void> _loadInstalled() async {
    try {
      final results = await Future.wait(
        ModelCatalog.all.map((m) async => (m.id, await _manager.isInstalled(m))),
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        for (final r in results) {
          _installed[r.$1] = r.$2;
        }
      });
    } catch (e) {
      if (!mounted) return;
      // On error, stop loading and show empty state
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    final List<String?> ids = await Future.wait<String?>([
      _manager.activeLlmId(),
      _manager.activeVisionId(),
      _manager.activeEmbeddingId(),
    ]);
    if (!mounted) return;
    setState(() {
      _llmId = ids[0];
      _visionId = ids[1];
      _embeddingId = ids[2];
    });
  }

  String? _selectedId(ModelKind kind) {
    switch (kind) {
      case ModelKind.llm:
        return _llmId;
      case ModelKind.vision:
        return _visionId;
      case ModelKind.embedding:
        return _embeddingId;
    }
  }

  /// Write [m] into the selection slot its **section** belongs to.
  ///
  /// Dispatching on `m.kind` is the same trap as checking
  /// `kind == ModelKind.llm` when deciding what is a chat model: Qwen3.5 is
  /// registered as `vision`, so tapping it under "Chat model" wrote
  /// `activeVisionId` and left `activeLlmId` pointing elsewhere — the row read
  /// as chosen while Load bound a different model. The tapped section is the
  /// authority, not the catalog's label for the model.
  Future<void> _chooseIn(ModelKind section, LocalModel m) async {
    switch (section) {
      case ModelKind.llm:
        await _manager.selectLlm(m.id);
        break;
      case ModelKind.vision:
        if (_visionId == m.id) {
          await _manager.selectVision(null);
        } else {
          await _manager.selectVision(m.id);
        }
        break;
      case ModelKind.embedding:
        await _manager.setActiveEmbeddingId(m.id);
        break;
    }
    await _refresh();
  }

  List<LocalModel> _catalog(ModelKind kind) {
    switch (kind) {
      case ModelKind.llm:
        return ModelCatalog.llms;
      case ModelKind.vision:
        return ModelCatalog.visionModels;
      case ModelKind.embedding:
        return ModelCatalog.embeddingModels;
    }
  }

  /// Derives the status chip label and tint for a model within [section].
  /// Uses the section's selection slot so Qwen3.5 under "Chat model" still
  /// reads as the loaded chat model rather than as a standalone vision pick.
  ///
  /// This method is kept for reference; the actual status is computed
  /// synchronously inside [_row] from the cached [_installed] map.
  _ModelStatus _modelStatus(LocalModel m, ModelKind section) {
    final selected = _selectedId(section) == m.id;
    if (!ModelCatalog.isUsable(m)) return _ModelStatus.notInstalled;
    final installed = _installed[m.id] ?? false;
    if (!installed) return _ModelStatus.notInstalled;
    if (selected) return _ModelStatus.selectedPending;
    return _ModelStatus.installed;
  }

  Widget _row(LocalModel m, ModelKind section, int index) {
    final usable = ModelCatalog.isUsable(m);
    final selected = _selectedId(section) == m.id;

    return FadeSlideIn(
      delay: staggerDelay(index),
      child: _ModelRowCard(
        model: m,
        section: section,
        selected: selected,
        installed: _installed[m.id] ?? false,
        usable: usable,
        status: _modelStatus(m, section),
        onTap: (usable && (_installed[m.id] ?? false))
            ? () => _chooseIn(section, m)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Watched rather than read: `_loadSelectedModels` writes `model_path` when
    // it finishes, and this row has to update the moment it does.
    final path = ref.watch(settingsProvider)['model_path'] as String?;
    final loadedFile = (path == null || path.isEmpty)
        ? null
        : path.substring(path.lastIndexOf('/') + 1);
    final loaded = loadedFile == null
        ? null
        : ModelPreflight.friendlyName(loadedFile);

    final selectedLlm = _llmId == null ? null : ModelCatalog.byId(_llmId);
    // Selected-but-not-loaded is the exact failure that produced "vision failed
    // to attach" with no explanation: the files are on disk, the user believes
    // they are in use, and they are not.
    final stale =
        loadedFile != null &&
        selectedLlm != null &&
        loadedFile != selectedLlm.fileName;

    // Show loading indicator while installing models are being detected.
    if (_loading) {
      return Container(
        constraints: const BoxConstraints(minHeight: 200),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return SizedBox(
      width: double.maxFinite,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -------------------------------------------------------- status card
            _LoadedModelCard(loaded: loaded),
            const SizedBox(height: 4),
            if (stale) const _StaleWarningBanner(),
            const SizedBox(height: 8),
            (() {
              final chatModel = _chatModelForWarning();
              if (chatModel != null &&
                  _isVisionArchIncompatible(
                    vision: _visionId != null
                        ? ModelCatalog.byId(_visionId)
                        : null,
                    chat: chatModel,
                  )) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: _ArchWarningCard(
                    chatModel: chatModel,
                    visionId: _visionId,
                  ),
                );
              }
              return const SizedBox.shrink();
            }()),

            const SizedBox(height: 4),

            // -------------------------------------------------------- my models
            // Aaron's own slots: blank until he fills them by loading a
            // file from storage, tapped to switch between them. The
            // catalog below stays the download list.
            ..._myModelsSection(context, path, text, scheme),
            const SizedBox(height: 4),

            // ------------------------------------------------ section dividers
            ..._section(context, 'Chat model', ModelKind.llm, text, scheme),
            const SizedBox(height: 4),
            ..._section(
              context,
              'Vision model',
              ModelKind.vision,
              text,
              scheme,
            ),
            const SizedBox(height: 4),
            ..._section(
              context,
              'Embeddings',
              ModelKind.embedding,
              text,
              scheme,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Aaron's own slots. Blank until he fills them by loading a file from
  /// storage; each row loads that file, so he can switch between his
  /// models without picking from storage again. [currentPath] is the
  /// loaded file, so its row reads as the one in use.
  List<Widget> _myModelsSection(
    BuildContext context,
    String? currentPath,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final widgets = <Widget>[
      _SectionHeader(title: 'My models', textColor: scheme.primary),
    ];
    if (_storageModels.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'Empty — load a model from storage and it will sit here.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
      return widgets;
    }
    for (var i = 0; i < _storageModels.length; i++) {
      widgets.add(_storageModelRow(_storageModels[i], currentPath, i));
    }
    return widgets;
  }

  Widget _storageModelRow(String filePath, String? currentPath, int index) {
    final fileName = filePath.split('/').last;
    final name = ModelPreflight.friendlyName(fileName);
    final isCurrent = currentPath == filePath;
    String size = '';
    try {
      size = _fmtBytes(File(filePath).lengthSync());
    } catch (_) {
      size = '';
    }
    return FadeSlideIn(
      delay: staggerDelay(index),
      child: Card(
        child: ListTile(
          leading: Icon(
            Icons.description_outlined,
            color: isCurrent
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(name),
          subtitle: Text(
            [
              if (size.isNotEmpty) size,
              isCurrent ? 'Loaded' : 'Tap to switch to this model',
            ].join(' · '),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Remove this slot (the file stays on the phone)',
            onPressed: () async {
              await StorageModelsStore.instance.remove(filePath);
              if (!mounted) return;
              setState(() => _storageModels.remove(filePath));
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
          onTap: () async {
            await widget.onLoadFile(filePath);
            // The load may have pruned a gone file; re-read the slots.
            await _loadStorageModels();
          },
        ),
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    ModelKind kind,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final models = _catalog(kind);
    return [
      _SectionHeader(title: title, textColor: scheme.primary),
      // The section is passed down explicitly: a model listed under "Chat
      // model" has to be selectable *as* the chat model even when its catalog
      // `kind` says otherwise (Qwen3.5, which is registered as `vision`).
      ...models.asMap().entries.map((e) => _row(e.value, kind, e.key)),
    ];
  }

  /// True when the selected chat model and vision model have incompatible
  /// architectures. Qwen3.5 carries its own vision encoder (qwen35 arch), so
  /// pairing it with a phi2 LLM like SmolLM2 is guaranteed to fail at the
  /// native layer — the projector expects qwen35 context and the LLM speaks
  /// phi2. The UI warns the user before they tap Load rather than letting the
  /// load fail with a confusing "vision failed to attach" message.
  bool _isVisionArchIncompatible({
    required LocalModel? vision,
    required LocalModel chat,
  }) {
    if (vision == null || vision.llmArch == null) return false;
    if (chat.id == vision.id) return false; // same model, compatible
    final chatArch = chat.llmArch;
    if (chatArch == null) return false;
    return chatArch != vision.llmArch;
  }

  /// The chat model the warning should name: the user's selection when there
  /// is one (and it resolves), otherwise null (no warning when nothing selected).
  LocalModel? _chatModelForWarning() =>
      (_llmId != null ? ModelCatalog.byId(_llmId) : null);
}

// --------------------------------------------------------------------------- widgets

/// Beautiful status card shown at the top of the picker.
///
/// Displays the currently loaded model (or a clear "nothing loaded" state) with
/// a gradient-inspired container that uses the brand colour. When the selected
/// model doesn't match what is actually in memory, a slim amber banner appears
/// beneath the card.
class _LoadedModelCard extends StatelessWidget {
  const _LoadedModelCard({required this.loaded});

  final String? loaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        gradient: loaded == null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surfaceContainerHigh,
                  scheme.surfaceContainerHighest,
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: 0.18),
                  scheme.primary.withValues(alpha: 0.07),
                ],
              ),
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(
          color: loaded == null
              ? scheme.outlineVariant.withValues(alpha: 0.4)
              : scheme.primary.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Icon circle
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: loaded == null
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.10)
                    : scheme.primary.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(
                  color: loaded == null
                      ? scheme.outline.withValues(alpha: 0.3)
                      : scheme.primary.withValues(alpha: 0.40),
                  width: 1.2,
                ),
              ),
              child: Icon(
                loaded == null ? Icons.memory_outlined : Icons.check_circle,
                size: 22,
                color: loaded == null
                    ? scheme.onSurfaceVariant
                    : scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            // Text
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    loaded ?? 'No model loaded',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: loaded == null ? scheme.onSurfaceVariant : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loaded == null
                        ? 'Select a model below, then tap Load'
                        : 'Running now',
                    style: text.bodySmall?.copyWith(
                      color: loaded == null
                          ? scheme.onSurfaceVariant
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Status chip
            if (loaded != null)
              _StatusChip(
                label: 'Loaded',
                color: AppColors.success,
                icon: Icons.check_rounded,
              ),
          ],
        ),
      ),
    );
  }
}

/// Slim amber warning bar shown when the selected model differs from the one in
/// memory. Placed directly beneath [_LoadedModelCard].
class _StaleWarningBanner extends StatelessWidget {
  const _StaleWarningBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.30),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The file in memory is not the model selected below. Tap Load to switch.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Architecture mismatch warning card.
///
/// Uses a red-tinted container with an explicit warning icon so the user sees
/// this as a blocking issue rather than a subtle text note.
class _ArchWarningCard extends StatelessWidget {
  const _ArchWarningCard({required this.chatModel, required this.visionId});

  final LocalModel chatModel;
  final String? visionId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final visionDisplay = visionId != null
        ? (ModelCatalog.byId(visionId)?.displayName ?? 'vision model')
        : 'vision model';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: scheme.error.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: scheme.error,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${chatModel.displayName} cannot use $visionDisplay. '
              'A picture model only works with the chat model it was made '
              'for. Select the vision model as the chat model instead.',
              style: text.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single model row rendered as a card with status badge and role icon.
class _ModelRowCard extends StatelessWidget {
  const _ModelRowCard({
    required this.model,
    required this.section,
    required this.selected,
    required this.installed,
    required this.usable,
    required this.status,
    required this.onTap,
  });

  final LocalModel model;
  final ModelKind section;
  final bool selected;
  final bool installed;
  final bool usable;
  final _ModelStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Card(
        elevation: selected ? 2 : 0,
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          side: BorderSide(
            color: selected
                ? scheme.primary.withValues(alpha: 0.45)
                : scheme.outlineVariant.withValues(alpha: 0.35),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Role / status icon
                _ModelRoleIcon(
                  model: model,
                  usable: usable,
                  selected: selected,
                  installed: installed,
                  status: status,
                ),
                const SizedBox(width: 10),
                // Title + meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        model.displayName,
                        style: text.titleMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: usable
                              ? selected
                                    ? scheme.primary
                                    : null
                              : scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        model.description,
                        style: text.bodySmall?.copyWith(
                          color: usable
                              ? scheme.onSurfaceVariant
                              : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // The header line for a downloaded model: what the
                      // file on disk says it is (name, kind, size). A bad
                      // file shows why instead, and never loads.
                      if (installed && usable) ...[
                        const SizedBox(height: 3),
                        _InspectorLine(model: model),
                      ],
                      if (!usable && model.unsupportedReason != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          model.unsupportedReason!,
                          style: text.bodySmall?.copyWith(
                            color: scheme.error.withValues(alpha: 0.8),
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Status badge
                _StatusBadge(
                  status: status,
                  installed: installed,
                  usable: usable,
                ),
                const SizedBox(width: 4),
                // Size tag
                if (usable) _SizeTag(label: model.sizeLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular icon showing the model's role and selection state.
class _ModelRoleIcon extends StatelessWidget {
  const _ModelRoleIcon({
    required this.model,
    required this.usable,
    required this.selected,
    required this.installed,
    required this.status,
  });

  final LocalModel model;
  final bool usable;
  final bool selected;
  final bool installed;
  final _ModelStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    late final Color tint;
    late final IconData icon;

    if (!usable) {
      tint = scheme.onSurfaceVariant.withValues(alpha: 0.4);
      icon = Icons.block;
    } else if (selected) {
      tint = scheme.primary;
      icon = model.kind == ModelKind.embedding
          ? Icons.check_circle
          : Icons.psychology;
    } else if (status == _ModelStatus.installed) {
      tint = AppColors.success;
      icon = model.kind == ModelKind.embedding
          ? Icons.dns_outlined
          : (model.kind == ModelKind.vision
                ? Icons.visibility_outlined
                : Icons.psychology_outlined);
    } else {
      tint = scheme.onSurfaceVariant.withValues(alpha: 0.5);
      icon = Icons.cloud_download_outlined;
    }

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: selected ? 0.18 : 0.10),
        shape: BoxShape.circle,
        border: Border.all(
          color: tint.withValues(alpha: selected ? 0.50 : 0.25),
          width: 1.2,
        ),
      ),
      child: Icon(icon, size: 17, color: tint),
    );
  }
}

/// Pill-shaped badge indicating download / selection status.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.status,
    required this.installed,
    required this.usable,
  });

  final _ModelStatus status;
  final bool installed;
  final bool usable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    late final String label;
    late final Color tint;
    late final IconData icon;

    if (!usable) {
      label = 'Unsupported';
      tint = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
      icon = Icons.block;
    } else if (status == _ModelStatus.selectedPending) {
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

    return _StatusChip(label: label, color: tint, icon: icon);
  }
}

/// Slim pill with icon + label. Used for both status badges and the "Loaded" chip.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Small size tag (e.g. "600 MB") shown to the right of the status badge.
class _SizeTag extends StatelessWidget {
  const _SizeTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant
            .withValues(alpha: 0.65),
      ),
    );
  }
}

/// Section header with a coloured accent line.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.textColor});

  final String title;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: textColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Thinking indicator shown while the model is generating.
///
/// Kept as a public class because it is part of the screen's vocabulary, but
/// rebuilt around the theme: the old grey spinner on a grey box was the only
/// un-themed element left on the transcript. It also now matches the rest of
/// the assistant's presentation — same bubble colour, same avatar — so the
/// reply does not appear to jump when it materialises.
class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key});

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // One full three-dot cycle. Short enough to feel like the model is
    // thinking rather than the app is hung, long enough for each dot's pulse
    // to be legible.
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final AnimationController _scaleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  @override
  void initState() {
    super.initState();
    _scaleController.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ScaleTransition(
      scale: CurvedAnimation(
        parent: _scaleController,
        curve: AppMotion.enter,
        reverseCurve: AppMotion.exit,
      ),
      child: FadeTransition(
        opacity: _scaleController,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.35),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/clawzilla-mark.png',
                    width: 17,
                    height: 17,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppColors.aiBubble,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.45),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PulsingDots(animation: _controller),
                    const SizedBox(width: 14),
                    Text(
                      'Thinking...',
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
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
}

/// Three dots that brighten one after another with a smooth wave animation.
///
/// An [Interval] per dot off a single controller, so the whole indicator is one
/// ticker rather than three animations that drift apart. The dots return to
/// their dim base between pulses instead of restarting from bright, which is
/// what makes the loop read as continuous rather than as three blinks.
class _PulsingDots extends StatelessWidget {
  const _PulsingDots({required this.animation});

  final Animation<double> animation;

  static const int _dotCount = 3;

  /// Active window for each dot as a fraction of the cycle.
  static const double _slot = 0.33;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurfaceVariant
        .withValues(alpha: 0.4);
    final peak = AppColors.accent;

    final pulses = [
      for (var i = 0; i < _dotCount; i++)
        CurvedAnimation(
          parent: animation,
          curve: Interval(i * _slot, (i + 1) * _slot, curve: Curves.easeInOut),
        ),
    ];

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _dotCount; i++) ...[
              Transform.scale(
                scale: 0.7 + (pulses[i].value * 0.6),
                child: Container(
                  width: 8,
                  height: 8,
                  margin: EdgeInsets.only(right: i != _dotCount - 1 ? 6 : 0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(base, peak, pulses[i].value),
                    boxShadow: pulses[i].value > 0.5
                        ? [
                            BoxShadow(
                              color: AppColors.accent.withValues(
                                alpha: 0.5 * pulses[i].value,
                              ),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The mode + effort switcher above the composer.
///
/// Chat is the plain default; Plan makes the model lay out steps before
/// acting; Code asks for working code before the explanation. Effort only
/// changes how long a reply may run (Low 256 / Med 512 / High 1024) —
/// a local model has no true reasoning knob to turn.
class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.mode,
    required this.effort,
    required this.onModeChanged,
    required this.onEffortChanged,
  });

  final String mode;
  final String effort;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<String> onEffortChanged;

  static const _compact = ButtonStyle(
    visualDensity: VisualDensity.compact,
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      // Clawziod look: a thin green top border frames the mode strip as a
      // terminal panel, matching the composer's own top border above it.
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        border: Border(
          top: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      // One row, six buttons: the mode segments and the effort segments
      // sit side by side instead of stacking in two rows. Each
      // SegmentedButton takes half the width; the 10pt labels fit in the
      // ~60 dp each segment gets.
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<String>(
              style: _compact,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'chat',
                  label: Text('Chat'),
                  tooltip: 'Just chat',
                ),
                ButtonSegment(
                  value: 'plan',
                  label: Text('Plan'),
                  tooltip: 'Plan first, then act',
                ),
                ButtonSegment(
                  value: 'code',
                  label: Text('Code'),
                  tooltip: 'Code first, then explain',
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onModeChanged(s.first),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SegmentedButton<String>(
              style: _compact,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'low',
                  label: Text('Low'),
                  tooltip: 'Short replies',
                ),
                ButtonSegment(
                  value: 'med',
                  label: Text('Med'),
                  tooltip: 'Normal replies',
                ),
                ButtonSegment(
                  value: 'high',
                  label: Text('High'),
                  tooltip: 'Long, step-by-step replies',
                ),
              ],
              selected: {effort},
              onSelectionChanged: (s) => onEffortChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// One header line for a downloaded model in the picker: what the file on
/// disk says it is. Resolves the installed path, reads the header, and
/// shows the summary — or the header-check error when the file is bad.
/// Shows nothing while loading or when the file cannot be found; the load
/// path reports the real error when the user taps Load.
class _InspectorLine extends StatefulWidget {
  const _InspectorLine({required this.model});

  final LocalModel model;

  @override
  State<_InspectorLine> createState() => _InspectorLineState();
}

class _InspectorLineState extends State<_InspectorLine> {
  String? _line;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? line;
    String? error;
    try {
      final path = await ModelManager.getInstance().weightPath(widget.model);
      final info = await ModelPreflight.inspect(path);
      if (info != null) {
        line = info.summaryLine;
      } else {
        error = await ModelPreflight.verify(path);
      }
    } catch (_) {
      // A missing file or unreadable header: show nothing rather than a
      // wrong line.
    }
    if (!mounted) return;
    setState(() {
      _done = true;
      _line = line;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_done || (_line == null && _error == null)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Text(
      _error ?? _line!,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: _error != null
            ? scheme.error
            : scheme.onSurfaceVariant,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
