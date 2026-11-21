/// LLM + vision service — local GGUF inference via llama.cpp.
///
/// Backed by `native_llama`, which vendors the whole llama.cpp tree (tools/mtmd
/// included) inside its pub archive so the NDK genuinely compiles libllama.so
/// into the APK. That detail is not cosmetic: `llama_cpp_dart` and
/// `flutter_llama` both point their CMake config at a `llama.cpp/` directory
/// that is absent from the published archive — the build succeeds and then the
/// app fails at runtime because the native library was never packaged.
///
/// ## The wire format is `text`, not `content`
///
/// `NativeLlama.generateResponse` does `messages.map((m) => m['text']!)`. Note
/// the `!`. Hand it `{'role':…, 'content':…}` — the OpenAI spelling, and the
/// obvious guess — and it throws a null-assertion *inside the stream
/// controller's onListen callback*, before `startGeneration` is ever invoked.
/// Nothing catches that: the error escapes as an unhandled zone error instead
/// of reaching the `await for` on the caller's side, and because the controller
/// is never closed the consuming stream simply never completes. The symptom is
/// a chat that sits on "Thinking…" forever with no error anywhere.
///
/// That is a genuinely nasty failure mode, so two things are true of this file:
/// the key is `text`, and nothing here is allowed to await a stream that has no
/// bound on how long it may stay silent. See [_prefillTimeout] and
/// [_decodeSilenceTimeout].
///
/// ## The token cap is enforced on both sides
///
/// Build #127: [maxTokens] is passed through the method channel to the
/// native loop (`scripts/patch_native_llama.py` adds the parameter to the
/// plugin at build time), so a generation with no listener ends after
/// `maxTokens` tokens instead of running until it hits an end-of-generation
/// token or fills the context window. Dart still enforces its own exact
/// cap as well, by aborting the native generation once the count is
/// reached — the native bound is a safety net for listener-less
/// generations, not the product cap.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:native_llama/native_llama.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/utils/log.dart';
import '../../core/utils/turn_builder.dart';
import '../../domain/models/local_model.dart';
import 'model_preflight.dart';

/// Bound on time-to-first-token: how long prefill may run before the turn
/// is treated as wedged.
///
/// Build #129 (local hang, Piece C — make the timer honest): measured on
/// the phone Nov 20, prefill runs ~512 tokens per ~44s (~11.6 tok/s), so
/// a 1,432-token normal prompt needs ~120–130s before the first token.
/// The old single 90s silence bound fired mid-prefill on every
/// normal-mode turn. 300s covers ~3,500 tokens at the measured rate,
/// with headroom over today's ~1,400-token prompts. This bound applies
/// ONLY before the first token; once decoding starts, the 90s
/// decode-silence bound below takes over, so the 90s number survives
/// nowhere as a prefill bound.
const Duration _prefillTimeout = Duration(seconds: 300);

/// Bound on silence AFTER the first token: how long decoding may go
/// without emitting a token before the turn is treated as wedged.
/// 90s of decode silence is the real "wedged" signal — prefill is done
/// by then, so a stall here means the engine stopped, not that it is slow.
const Duration _decodeSilenceTimeout = Duration(seconds: 90);

/// Hard ceiling on wall-clock time for one generation, regardless of progress.
///
/// 10 minutes = the 300s prefill bound plus room for a full 512-token
/// decode at phone speed. The old 5-minute ceiling would have fired on a
/// legitimate slow turn the moment prefill alone approached 300s.
const Duration _totalGenerationTimeout = Duration(minutes: 10);

class LlmService {
  static LlmService? _instance;

  final NativeLlama _llm = NativeLlama();

  /// The bounds above, exposed for tests. The split is the fix: if the
  /// prefill bound ever collapses back to 90s, normal-mode turns time out
  /// mid-prefill again the moment the prompt grows.
  @visibleForTesting
  static Duration get prefillTimeout => _prefillTimeout;
  @visibleForTesting
  static Duration get decodeSilenceTimeout => _decodeSilenceTimeout;
  @visibleForTesting
  static Duration get totalGenerationTimeout => _totalGenerationTimeout;

  // Default context window (build #99: raised from 2048). The full local
  // prompt (saved memories, core skills, tools section) plus history was
  // starving the context on safe-mode-off turns — the native prefill then
  // failed silently and the turn timed out with no token. 4096 gives the
  // prompt headroom; the turn builder uses this as the token budget, so
  // history grows with it. One source of truth: the field initializer and
  // [loadModel]'s default both read this, and a test pins it.
  static const int defaultContextSize = 4096;

  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = defaultContextSize;
  int _gpuLayers = 0;
  int _threads = 4;

  String? _visionProjectorPath;
  bool _isVisionLoaded = false;

  /// Which backend is actually running: 'vulkan', 'cpu', or 'unknown'.
  /// Updated after each successful load; null until first load.
  String? _activeBackend;

  /// True while a generation is in flight, so the UI can offer "Stop".
  bool _isGenerating = false;

  /// The in-flight generation's token bridge, when one is running. `stop()`
  /// closes it so the `await for` in `generateStream` ends at once — the
  /// native abort is supposed to close the plugin stream, but on the
  /// patched engine it does not always do so promptly, and without this
  /// the consumer waits forever, `_isThinking` stays true, and the Stop
  /// button never flips back to Send.
  StreamController<String>? _activeBridge;

  /// Fires for every generated token (same data as the stream).
  void Function(String token)? onToken;

  /// Fires instead of throwing so the UI can surface a message.
  void Function(String error)? onError;

  /// Drop both callbacks.
  ///
  /// [LlmService] is a singleton, so a callback assigned by a screen outlives
  /// that screen unless something clears it — and the next generation would
  /// then call `setState` on a disposed widget. Call this from `dispose`.
  /// Invocations are also guarded (see [_notifyToken]), so a missed call here
  /// degrades to a logged warning instead of a stalled stream, but clearing is
  /// still the right thing for a screen to do.
  void clearCallbacks() {
    onToken = null;
    onError = null;
  }

  /// Invoke [onToken] without letting a dead listener break generation.
  ///
  /// The callback runs inside the plugin stream's listener, which is exactly
  /// where an uncaught exception is worst: it escapes the stream entirely as an
  /// unhandled zone error, and — because it happens *before* the token is
  /// forwarded — the consumer's `await for` never receives it either. That is
  /// the "Thinking…" spinner that never resolves. A `setState()` on a disposed
  /// widget was enough to trigger it.
  void _notifyToken(String token) {
    final cb = onToken;
    if (cb == null) return;
    try {
      cb(token);
    } catch (e) {
      Log.w('[LlmService] token callback threw; continuing: $e');
    }
  }

  /// Invoke [onError] without letting a dead listener mask the real failure.
  void _notifyError(String message) {
    final cb = onError;
    if (cb == null) return;
    try {
      cb(message);
    } catch (e) {
      Log.w('[LlmService] error callback threw ($e); reporting: $message');
    }
  }

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// Number of usable CPU cores for inference.
  ///
  /// [performanceOnly] asks the platform for the big cores only. On the
  /// big.LITTLE Android SoCs this app targets, handing llama.cpp every core
  /// including the little ones tends to *reduce* throughput, because the slow
  /// cores become the stragglers in every synchronised matmul.
  ///
  /// The result is capped at [_maxInferenceThreads]. Decode is memory-bandwidth
  /// bound, so past roughly four threads the extra workers contend for the same
  /// memory bus and generation gets slower rather than faster. The cost is some
  /// prompt-processing throughput, which is the right trade for a chat app
  /// where time-to-first-token and streaming smoothness are what a person
  /// actually notices.
  Future<int> cpuCores({bool performanceOnly = true}) async {
    try {
      final cores = await _llm.getCpuCores(performanceOnly: performanceOnly);
      if (cores <= 0) return _threads;
      return cores < _maxInferenceThreads ? cores : _maxInferenceThreads;
    } catch (e) {
      // The device could not be interrogated, so fall back to the configured
      // thread count rather than failing the load outright — but say so, because
      // "the phone told us it has 8 cores and we used 4" and "we could not ask"
      // are different problems with different fixes.
      Log.w('[LlmService] core count unavailable, using $_threads: $e');
      return _threads;
    }
  }

  static const int _maxInferenceThreads = 4;

  /// Current thread count setting (default 4, max 4).
  int get threads => _threads;

  /// Set the thread count. Capped at [_maxInferenceThreads].
  void setThreads(int n) {
    _threads = n.clamp(1, _maxInferenceThreads);
  }

  /// Why the last [loadModel] failed, or null if it has not failed (or the
  /// most recent attempt succeeded).
  ///
  /// The chat screen shows this instead of a bare "Failed to load model", so
  /// the user gets the actual native error rather than having to guess between
  /// OOM, a corrupt file and a broken GPU driver.
  String? get lastLoadError => _lastLoadError;
  String? _lastLoadError;

  /// Load a GGUF chat model. Returns false (and reports via [onError]) on
  /// failure rather than throwing, so the UI can show a message.
  ///
  /// [gpuLayers] is how many transformer layers to offload. The value is
  /// requested rather than guaranteed: when the native side refuses the GPU
  /// path this method retries once at zero layers on CPU before it reports
  /// failure, because a device with a broken Vulkan stack can still run the
  /// model — just slower. [GpuCapability] decides what to ask for.
  ///
  /// On success, [activeBackend] is updated to reflect what actually ran.
  ///
  /// [totalRamMb] is total device RAM in MB (0 = unknown, RAM gate
  /// skipped). See [ModelPreflight].
  Future<bool> loadModel(
    String modelPath, {
    int nCtx = defaultContextSize,
    int gpuLayers = 0,
    int totalRamMb = 0,
  }) async {
    // Safe loader (Clawzilla v1): refuse bad files BEFORE any native
    // call. A native crash below Dart cannot be caught, so pre-flight is
    // the defence. A pre-flight failure leaves any currently loaded model
    // untouched and reports through the normal error path.
    final preflightError = await ModelPreflight.verify(modelPath) ??
        await ModelPreflight.checkFits(modelPath, totalRamMb);
    if (preflightError != null) {
      _lastLoadError = preflightError;
      _notifyError(preflightError);
      return false;
    }
    try {
      await release();
      _nCtx = nCtx;

      var layers = gpuLayers;
      var error = await _initOnce(modelPath, nCtx, layers);

      // A GPU offload the device refuses (no usable Vulkan device, driver
      // quirk, thermal/RAM pressure) otherwise surfaces as "the model will not
      // load, ever" — which is exactly what a user sees as a dead Load button.
      // llama.cpp on CPU loads the same file fine, so retry once at zero
      // layers before reporting failure, and remember which one worked.
      if (error != null && layers > 0) {
        Log.w('[LlmService] GPU init failed ($error) — retrying on CPU');
        await release();
        layers = 0;
        error = await _initOnce(modelPath, nCtx, 0);
      }

      if (error != null) {
        _lastLoadError = error;
        _notifyError(error);
        _isLoaded = false;
        _modelPath = null;
        _activeBackend = null;
        _gpuLayers = 0;
        return false;
      }

      _gpuLayers = layers;
      // Reported from the layers that were actually accepted, not requested.
      _activeBackend = layers > 0 ? 'vulkan' : 'cpu';
      _modelPath = modelPath;
      _isLoaded = true;
      _lastLoadError = null;
      debugPrint(
        '[LlmService] loaded $modelPath (ctx=$nCtx, gpuLayers=$layers, threads=${_threads}, backend=$_activeBackend)',
      );
      return true;
    } catch (e) {
      _notifyError('Failed to load model: $e');
      _isLoaded = false;
      _modelPath = null;
      _activeBackend = null;
      _gpuLayers = 0;
      return false;
    }
  }

  /// One native init attempt. Returns null on success, or the message to show
  /// the user on failure. Never throws and never calls [onError] itself: a
  /// failed *first* attempt is recoverable by the CPU retry in [loadModel], and
  /// reporting an error the app then recovers from would be a false alarm.
  Future<String?> _initOnce(String path, int nCtx, int layers) async {
    try {
      await _llm.initModel(
        path,
        nCtx: nCtx,
        nThreads: await cpuCores(),
        nGpuLayers: layers,
      );
      if (_llm.isInitialized) return null;
      return 'Native layer rejected the model (too large for RAM?)';
    } catch (e) {
      Log.e('[LlmService] init failed (layers=$layers): $e');
      return 'Failed to load model: $e';
    }
  }

  /// Why the last [loadVision] call failed, or null if it never has.
  ///
  /// The chat screen shows this instead of a bare "vision failed to attach",
  /// so the user gets an actual cause rather than having to guess.
  String? get lastVisionError => _lastVisionError;
  String? _lastVisionError;

  /// Load the mmproj projector that makes a vision model usable.
  ///
  /// Kept separate from [loadModel] because the projector belongs to the vision
  /// model, not the chat model, and the two are downloaded independently.
  Future<bool> loadVision(String mmprojPath) async {
    try {
      await _llm.initVision(mmprojPath);
      _visionProjectorPath = mmprojPath;
      _isVisionLoaded = true;
      _lastVisionError = null;
      Log.i('[LlmService] vision projector loaded: $mmprojPath');
      return true;
    } catch (e) {
      _isVisionLoaded = false;
      _visionProjectorPath = null;
      // The plugin's own failure text is the only real diagnostic here, so it
      // must reach the log and the UI rather than being replaced by a generic
      // message.
      _lastVisionError = 'Vision projector failed: $e';
      Log.e('$_lastVisionError (path: $mmprojPath)');
      _notifyError(_lastVisionError!);
      return false;
    }
  }

  /// Turn a list of messages into the plugin's wire format.
  ///
  /// The key is `text`. See the library docstring — using `content` here is the
  /// bug that hangs the chat screen with no error. Exposed for the regression
  /// test in `test/llm_wire_format_test.dart`, which exists precisely because
  /// this mistake is invisible until you run it on a device.
  @visibleForTesting
  static List<Map<String, String>> wire(
    String prompt, {
    String? systemPrompt,
    List<Map<String, String>> history = const [],
  }) {
    return [
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        {'role': 'system', 'text': systemPrompt},
      for (final m in history)
        if ((m['text'] ?? m['content'] ?? '').isNotEmpty)
          {
            'role': m['role'] ?? 'user',
            'text': m['text'] ?? m['content'] ?? '',
          },
      {'role': 'user', 'text': prompt},
    ];
  }

  /// Estimated prompt size of a [wire] message list, in tokens.
  ///
  /// Build #126 (local hang, Piece A — measure): the number that decides
  /// whether a slow prefill or a dead engine is behind the 90s timeout.
  /// Uses the same ~4 chars/token rule as [estimateTokens], so the Dart
  /// log and the turn builder agree; the native trace carries the exact
  /// count (`tokenize: N prompt tokens`).
  @visibleForTesting
  static int estimateWireTokens(List<Map<String, String>> wire) {
    final text = wire.map((m) => m['text'] ?? '').join();
    return estimateTokens(text);
  }

  /// Report whether the native trace file exists and how big it is.
  ///
  /// Build #126: the native trace was empty after a working turn on the
  /// phone, which means either the path was never set or the native glue
  /// never wrote. This line, in the Activity log after every local turn,
  /// says which — without opening the Diagnostics screen. The file name
  /// must match DiagnosticsScreen.traceFileName and the path the Kotlin
  /// side sets ("app_flutter/native_trace.log"); if any side disagrees,
  /// this reports MISSING and the trace section shows "No native trace
  /// yet". Fire-and-forget: a failed check is itself logged, never thrown.
  /// The native trace file, or null when the docs dir cannot be resolved.
  static Future<File?> _traceFile() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return File('${docs.path}/native_trace.log');
    } catch (_) {
      return null;
    }
  }

  /// One native prefill-chunk line in the trace, e.g.
  /// `[23:30:56.704] prefill: chunk at 512/1432 tokens rc=0`.
  static final _prefillChunkPattern = RegExp(
    r'prefill: chunk at (\d+)/(\d+) tokens',
  );

  /// The latest prefill progress in [traceText], or null when it holds no
  /// prefill-chunk line. Takes the LAST match: the trace is append-mode,
  /// so the tail of the file is the newest chunk. Pure, so the timer
  /// tests can pin it without a file or a plugin.
  @visibleForTesting
  static ({int done, int total})? parsePrefillProgress(String traceText) {
    final matches = _prefillChunkPattern.allMatches(traceText);
    if (matches.isEmpty) return null;
    final last = matches.last;
    return (
      done: int.parse(last.group(1)!),
      total: int.parse(last.group(2)!),
    );
  }

  /// Bytes appended to [file] after [offset], as text. The trace is
  /// append-mode (truncated only past 200 KB), so a turn that remembers
  /// its starting offset reads only its own lines — chunk lines from
  /// earlier turns are ignored by construction. A file that shrank below
  /// the offset (a truncate mid-turn) is read from the start instead.
  /// Never throws: a failed read is empty progress, not a failed turn.
  static Future<String> _readTraceTail(File file, int offset) async {
    try {
      final length = await file.length();
      final start = length < offset ? 0 : offset;
      if (length <= start) return '';
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(length - start);
        return utf8.decode(bytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  static Future<void> _logTraceHealth() async {
    final file = await _traceFile();
    if (file == null) {
      Log.w('[LlmService] native trace health check failed: no docs dir');
      return;
    }
    try {
      if (await file.exists()) {
        Log.i(
          '[LlmService] native trace: exists, ${await file.length()} bytes',
        );
      } else {
        Log.w(
          '[LlmService] native trace: MISSING — the native glue is not '
          'writing to ${file.path}',
        );
      }
    } catch (e) {
      Log.w('[LlmService] native trace health check failed: $e');
    }
  }

  /// Stream generated tokens one at a time.
  ///
  /// Pass [imagePath] to feed a picture to a vision model. This **requires**
  /// [isVisionLoaded]. When it is false we throw instead of proceeding, because
  /// the plugin drops unsupported media silently and the model will then answer
  /// a question it never actually received.
  ///
  /// Stops early once [maxTokens] tokens have been emitted. The native
  /// loop is bounded by the same number (build #127), so a listener-less
  /// generation ends by itself; Dart's cap is still the exact one.
  ///
  /// [onPrefillProgress] is called with (done, total) prompt tokens as
  /// prefill progresses, read from the native trace (build #129, Piece C).
  /// It fires only before the first token — decoding progress is the
  /// tokens themselves. Null when the caller does not show progress.
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    String? systemPrompt,
    List<Map<String, String>> history = const [],
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    String? imagePath,
    void Function(int done, int total)? onPrefillProgress,
  }) async* {
    if (!_isLoaded) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    if (!_llm.isInitialized) {
      throw StateError(
        'The native model is not initialised. Reload the model and try again.',
      );
    }

    // Never let a picture disappear. The plugin discards media when no
    // projector is attached, which yields a confident answer to a question the
    // model never actually received.
    if (imagePath != null && !_isVisionLoaded) {
      throw StateError(
        'Cannot send an image: no vision model is loaded. The picture '
        'would be dropped and the model would answer as if it had seen '
        'nothing. Load a vision model first.',
      );
    }

    final wire = LlmService.wire(
      prompt,
      systemPrompt: systemPrompt,
      history: history,
    );

    if (wire.isEmpty) {
      throw StateError('Nothing to send: the message list is empty.');
    }

    // Build #126 (local hang, Piece A — measure): the prompt size and the
    // time to the first token are the two numbers that decide whether a
    // slow prefill or a dead engine is behind the 90s timeout. The native
    // trace carries the exact token count; Dart logs the estimate so the
    // number is visible in the Activity log even when the native trace
    // is empty.
    final startedAt = DateTime.now();
    final promptTokensEst = estimateWireTokens(wire);
    Log.i(
      '[LlmService] local turn started: prompt ~$promptTokensEst tokens '
      '(est, ${wire.length} msgs), model=$_modelPath, ctx=$_nCtx, '
      'threads=$_threads',
    );

    _isGenerating = true;

    // Build #129 (Piece C): the trace offset this turn started at. The
    // trace is append-mode, so the prefill poller below reads only bytes
    // appended after this point — chunk lines from earlier turns never
    // leak into this turn's progress.
    final traceFile = await _traceFile();
    var traceOffset = 0;
    if (traceFile != null) {
      try {
        traceOffset = await traceFile.length();
      } catch (_) {
        traceOffset = 0;
      }
    }

    // Bridge the plugin's stream so we can impose our own bounds on it.
    final bridge = StreamController<String>();
    _activeBridge = bridge;
    StreamSubscription<String>? sub;
    Timer? silenceTimer;
    Timer? totalTimer;
    Timer? prefillPollTimer;
    var emitted = 0;
    var finished = false;
    var lastPrefillDone = -1;

    void cancelPrefillPoll() {
      prefillPollTimer?.cancel();
      prefillPollTimer = null;
    }

    Future<void> pollPrefillProgress() async {
      // Decoding has started (or the turn ended): prefill is over, and
      // the tokens themselves are the progress now.
      if (finished || emitted > 0 || traceFile == null) return;
      final progress = parsePrefillProgress(
        await _readTraceTail(traceFile, traceOffset),
      );
      if (progress == null || progress.done <= lastPrefillDone) return;
      lastPrefillDone = progress.done;
      Log.i(
        '[LlmService] prefill progress: ${progress.done}/${progress.total} '
        'tokens',
      );
      onPrefillProgress?.call(progress.done, progress.total);
    }

    void finish() {
      if (finished) return;
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      cancelPrefillPoll();
      // Build #126: say whether the native trace exists after a finished
      // turn — the trace is the evidence for what the native side did.
      unawaited(_logTraceHealth());
      if (!bridge.isClosed) bridge.close();
    }

    void fail(Object error) {
      if (finished) return;
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      cancelPrefillPoll();
      // The bridge is about to end, so nothing further will be read from the
      // plugin stream. Whatever the native side was doing has to be told to
      // stop: on the timeout paths this is a second abort (harmless — `stop`
      // swallows its own failures), and on a mid-generation plugin error it is
      // the only thing that prevents llama.cpp from generating into a void.
      unawaited(stop());
      Log.w(
        '[LlmService] generation failed: $error '
        '(after ${DateTime.now().difference(startedAt).inSeconds}s; '
        'prompt ~$promptTokensEst tokens (est))',
      );
      // Build #126: say whether the native trace exists after a failed
      // turn — a missing file after a timeout is itself the diagnosis.
      unawaited(_logTraceHealth());
      if (!bridge.isClosed) bridge.addError(error);
      if (!bridge.isClosed) bridge.close();
    }

    void resetSilenceTimer() {
      silenceTimer?.cancel();
      // Build #129 (Piece C): the two bounds are different jobs. Before
      // the first token the turn is still prefilling — a slow prefill is
      // expected on this phone, so the bound is the generous prefill one.
      // After the first token, 90s of silence means the engine stalled.
      // The old single 90s bound conflated the two and fired mid-prefill
      // on every normal-mode turn.
      final prefilling = emitted == 0;
      final bound = prefilling ? _prefillTimeout : _decodeSilenceTimeout;
      silenceTimer = Timer(bound, () {
        // Nothing has arrived for a long time. Stop the native loop rather than
        // leaving the UI waiting on a stream that may never complete.
        unawaited(stop());
        fail(
          TimeoutException(
            prefilling
                ? 'The model is still processing the prompt after '
                    '${bound.inSeconds}s without a token. The prompt may '
                    'be too long for this phone — try safe mode or a '
                    'shorter chat.'
                : 'The model stopped responding. Generation was cancelled '
                    'after ${bound.inSeconds}s without a token.',
          ),
        );
      });
    }

    try {
      // Anything thrown while *building* the stream surfaces here rather than
      // vanishing into onListen, which is the failure the docstring describes.
      final out = _llm.generateResponse(
        wire,
        mediaPaths: imagePath == null ? null : [imagePath],
        temperature: temperature,
        topP: topP,
        topK: topK,
        // Build #127: thread the cap through to the native loop, so a
        // listener-less generation ends by itself after maxTokens.
        maxTokens: maxTokens,
      );

      sub = out.listen(
        (token) {
          if (finished || token.isEmpty) return;
          // Count first, then arm the timer: the bound depends on
          // whether a token has arrived yet (build #129 — prefill 300s
          // before the first token, decode silence 90s after it).
          emitted++;
          resetSilenceTimer();

          if (emitted == 1) {
            // Prefill is over — the poller has nothing left to report.
            cancelPrefillPoll();
            // Build #126: time-to-first-token, from the caller's side —
            // this is the number the 90s silence timer is really
            // measuring, and the one Piece A exists to capture.
            final firstMs =
                DateTime.now().difference(startedAt).inMilliseconds;
            Log.i(
              '[LlmService] first token after ${firstMs}ms; '
              'prompt ~$promptTokensEst tokens (est)',
            );
          }
          _notifyToken(token);
          if (!bridge.isClosed) bridge.add(token);

          if (emitted >= maxTokens) {
            // The plugin will keep going otherwise.
            unawaited(stop());
            finish();
          }
        },
        onError: fail,
        onDone: finish,
        cancelOnError: false,
      );

      totalTimer = Timer(_totalGenerationTimeout, () {
        unawaited(stop());
        fail(
          TimeoutException(
            'Generation exceeded ${_totalGenerationTimeout.inMinutes} minutes '
            'and was cancelled.',
          ),
        );
      });

      resetSilenceTimer();

      // Build #129 (Piece C): while the first token is still outstanding,
      // read the native trace every 2s for prefill-chunk lines. The
      // chunk rate on this phone is ~one line per 44s, so 2s polling
      // reports each chunk promptly without hammering the file. Stops
      // on the first token (cancelled in the listener), on finish/fail,
      // and in the finally below — it never outlives the turn.
      prefillPollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(pollPrefillProgress()),
      );

      await for (final token in bridge.stream) {
        yield token;
      }
    } catch (e) {
      _notifyError('Generation error: $e');
      rethrow;
    } finally {
      // Capture this *before* the teardown marks the generation finished.
      //
      // `finished` is true when the generation ended the way it should: the
      // plugin's stream completed, the token cap was reached, or a timeout
      // already aborted the native side. It is false when the `finally` runs
      // because the *consumer* walked away — the user pressed Stop, or the
      // widget that was streaming was disposed.
      //
      // Cancelling the Dart subscription in that case does nothing to llama.cpp
      // by itself: the native loop is bounded by maxTokens (build #127), so
      // it ends on its own — but only after generating up to that many tokens
      // into the void. Nothing was listening, so nobody would ever stop it
      // sooner — the model would keep generating (and keep the context window
      // locked) after the screen that asked for it was gone. Aborting here is
      // the prompt way to end that; the native bound is the backstop.
      //
      // Deliberately not awaited, matching every other `stop()` in this file: a
      // teardown that can block on a platform call is the exact failure mode
      // this method exists to avoid, and `stop` swallows its own errors.
      final consumerLeft = !finished;
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      cancelPrefillPoll();
      if (consumerLeft) unawaited(stop());
      await sub?.cancel();
      if (!bridge.isClosed) await bridge.close();
      if (identical(_activeBridge, bridge)) _activeBridge = null;
      _isGenerating = false;
    }
  }

  /// Convenience wrapper that collects the whole response.
  /// One-shot generation. Sampling parameters default to the chat
  /// defaults; the Prompt Lab passes its own sliders through here, which
  /// is what makes them actually affect the model.
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    String? systemPrompt,
    List<Map<String, String>> history = const [],
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    String? imagePath,
  }) async {
    final buffer = StringBuffer();
    await for (final token in generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      systemPrompt: systemPrompt,
      history: history,
      temperature: temperature,
      topP: topP,
      topK: topK,
      imagePath: imagePath,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  /// Ask the currently loaded vision model to describe [imagePath].
  Future<String> describeImage(
    String imagePath, {
    String instruction = 'Describe this image in detail.',
  }) {
    return generate(prompt: instruction, imagePath: imagePath, maxTokens: 400);
  }

  /// Interrupt an in-flight generation.
  Future<void> stop() async {
    try {
      await _llm.abortGeneration();
    } catch (_) {
      // Nothing running.
    }
    _isGenerating = false;
    // End the Dart-side stream as well. The native abort is supposed to
    // close the plugin stream, but on the patched engine it does not
    // always do so promptly — without this, the `await for` in
    // `generateStream` never ends, the turn never finishes, and the Stop
    // button never flips back to Send. Not awaited: closing the bridge
    // only has to start, and awaiting it here could stall the caller
    // while the consumer unwinds.
    final bridge = _activeBridge;
    if (bridge != null && !bridge.isClosed) {
      unawaited(bridge.close());
    }
  }

  /// Free native resources.
  Future<void> release() async {
    await stop();
    try {
      await _llm.dispose();
    } catch (_) {
      // Already disposed / never initialised.
    }
    _isLoaded = false;
    _modelPath = null;
    _activeBackend = null;
    _isVisionLoaded = false;
    _visionProjectorPath = null;
    _gpuLayers = 0;
  }

  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  String? get modelPath => _modelPath;
  int get contextSize => _nCtx;
  int get gpuLayers => _gpuLayers;
  bool get isVisionLoaded => _isVisionLoaded;
  String? get visionProjectorPath => _visionProjectorPath;

  /// Which backend is currently active: 'vulkan', 'cpu', or null before any load.
  String? get activeBackend => _activeBackend;

  /// True when [model] can answer image questions in the current session.
  bool canSee(LocalModel model) =>
      _isLoaded && _isVisionLoaded && model.isVision;
}
