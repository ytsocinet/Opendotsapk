/// First-run onboarding.
///
/// Three screens, and every one of them says something true about how the app
/// behaves. An onboarding that oversells privacy and then sends prompts to a
/// cloud API would be worse than none, so the copy matches the actual defaults:
/// on-device by default, cloud only if the user opts in.
///
/// The third page is the "ready" page and is the only one that commits
/// anything: [onboarding_done] is written there, exactly as before, and the
/// same code path is taken by Skip. A skip button that quietly did less than
/// the primary action would make the three choices at the bottom equivalent
/// when they are not.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/motion.dart';
import '../providers/providers.dart';
import 'main_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// Peek factor: the next page shows a sliver of itself, which is the only
  /// affordance that says "there is more to the right" on a gesture-driven
  /// screen where nothing else moves until you commit to a swipe.
  final PageController _pages = PageController(viewportFraction: 0.92);

  int _index = 0;

  /// Diagnostic (build #30 crash): what the settings save actually did,
  /// shown on this screen instead of swallowed. Null until the user taps
  /// Skip or Get started; 'Saving…' while the write is in flight; then the
  /// real outcome — 'Saved OK' or 'Save failed: <error>'. The Continue
  /// button below only appears once this is set, so the save and the
  /// navigation are tested as two separate steps.
  String? _saveStatus;

  /// Kept as a const list so the three slides are the same widget instances
  /// across rebuilds and the controller's page cache is not thrown away by
  /// every setState from the indicator.
  static const List<_Slide> _slides = [
    _Slide(
      icon: Icons.shield_outlined,
      title: 'Nothing leaves by default',
      body:
          'The assistant runs on this device. Your messages, notes and memory '
          'are stored here and encrypted at rest.\n\n'
          'The only tool that touches the network is web search, and only if '
          'you turn it on.',
    ),
    _Slide(
      icon: Icons.memory,
      title: 'Download a model to begin',
      body:
          'Clawzilla is the engine; the model is the brain. You pick one and '
          'the app downloads it.\n\n'
          'Start with Qwen2.5 0.5B (~397 MB) on a mid-range phone, or '
          'SmolLM2 360M if storage is tight.',
    ),
    _Slide(
      icon: Icons.cloud_queue,
      title: 'Cloud is optional, and yours',
      body:
          'If you ever want a bigger model, add your own API key. It is kept '
          "in this device's hardware keystore and never uploaded.\n\n"
          'You choose when cloud is used — or forbid it entirely with private '
          'mode.',
    ),
  ];

  bool get _isLast => _index == _slides.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, index) {
                  final slide = _slides[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FadeSlideIn(
                      // Each slide arrives on its own, not on page change:
                      // the entrance animation belongs to the screen
                      // appearing, and replaying it mid-swipe makes the
                      // gesture feel like it is fighting the UI.
                      duration: AppMotion.slow,
                      child: slide,
                    ),
                  );
                },
              ),
            ),
            _PageDots(
              count: _slides.length,
              index: _index,
              activeColor: scheme.primary,
              inactiveColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            if (_saveStatus != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  _saveStatus!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (_saveStatus != null && _saveStatus != 'Saving…') ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _enter,
                    child: const Text('Continue'),
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  if (!_isLast) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _back,
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(_isLast ? 'Get started' : 'Next'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _back() async {
    if (_index == 0) return;
    await _pages.previousPage(
      duration: AppMotion.base,
      curve: AppMotion.standard,
    );
  }

  Future<void> _next() async {
    if (!_isLast) {
      await _pages.nextPage(
        duration: AppMotion.base,
        curve: AppMotion.standard,
      );
      return;
    }

    await _finish();
  }

  /// Commit first-run — save only, no navigation.
  ///
  /// Diagnostic split (build #30 crash): on build #30 both buttons killed
  /// the app the instant they were tapped and the flag never persisted, so
  /// the save and the navigation are tested as two separate steps. This
  /// method only writes the flag and reports the real outcome on screen.
  /// [_enter] does only the navigation, and only after the user taps
  /// Continue. Whichever step crashes tells us where the fault is.
  Future<void> _finish() async {
    setState(() => _saveStatus = 'Saving…');
    try {
      await ref
          .read(settingsProvider.notifier)
          .updateSetting('onboarding_done', true)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() => _saveStatus = 'Saved OK — tap Continue to enter the app.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveStatus = 'Save failed: $e');
    }
  }

  /// Enter the app — navigation only, no settings write.
  ///
  /// Bisection (build #32 crash): tapping Continue in build #32 still
  /// killed the app, even though the destination was the main screen, not
  /// the model picker. So neither destination screen is proven at fault —
  /// the fault could be in the move itself or in something both screens
  /// share. This build lands on a bare screen with nothing in it: if it
  /// opens, the move is fine and the fault is in the real screens; if it
  /// crashes too, the fault is in the move itself. The button on that
  /// screen opens the real app with a plain push, so either way the user
  /// can still get in if the bare screen holds.
  void _enter() {
    Navigator.of(context)
        .pushReplacement(AppPageRoute(builder: (_) => const _EnteredScreen()));
  }
}

/// The bare landing screen from the onboarding bisection.
///
/// Deliberately almost nothing: a Scaffold, one line of text, and a button
/// that opens the real app with a plain push. No model list, no chat, no
/// bottom nav, no providers read — so if this screen opens, the navigation
/// itself is sound and the crash lives in the real screens' content.
///
/// Diagnostic extras (build #33 crash): it shows the last crash log if one
/// was written (see main.dart), and a "Test engine" button that constructs
/// the model engine on its own — if that tap crashes, the engine itself is
/// the fault; if it reports fine, the fault is elsewhere in the real screens.
class _EnteredScreen extends ConsumerStatefulWidget {
  const _EnteredScreen();

  @override
  ConsumerState<_EnteredScreen> createState() => _EnteredScreenState();
}

class _EnteredScreenState extends ConsumerState<_EnteredScreen> {
  String? _crashLog;
  String? _engineStatus;
  String? _startupLog;

  @override
  void initState() {
    super.initState();
    _loadCrashLog();
  }

  /// Reads the phone's own startup log (logcat) and keeps the lines that
  /// mention the plugin registration. The generated registrant logs a line
  /// like "Error registering plugin sqflite, ..." when a plugin's startup
  /// throws — that line is the exact reason the database never loaded, and
  /// an app can read its own log lines without any extra permission.
  Future<void> _loadStartupLog() async {
    setState(() => _startupLog = 'Reading the startup log…');
    try {
      final result = await Process.run('logcat', ['-d', '-v', 'brief']);
      final out = result.stdout as String;
      final lines = out.split('\n').where((line) {
        final lower = line.toLowerCase();
        return lower.contains('sqflite') ||
            lower.contains('registrant') ||
            lower.contains('error registering') ||
            lower.contains('flutter');
      }).toList();
      final shown = lines.length > 30
          ? lines.sublist(lines.length - 30)
          : lines;
      if (!mounted) return;
      setState(() => _startupLog = shown.isEmpty
          ? 'No matching lines in the startup log.'
          : shown.join('\n'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _startupLog = 'Could not read the log: $e');
    }
  }

  Future<void> _loadCrashLog() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/crash.log');
      if (!await file.exists()) return;
      final text = await file.readAsString();
      if (!mounted || text.trim().isEmpty) return;
      setState(() {
        _crashLog = text.length > 2000
            ? text.substring(text.length - 2000)
            : text;
      });
    } catch (_) {
      // No log, no problem — a native crash writes nothing at all.
    }
  }

  Future<void> _testEngine() async {
    setState(() => _engineStatus = 'Testing the engine…');
    try {
      final llm = ref.read(llmServiceProvider);
      if (!mounted) return;
      setState(() {
        _engineStatus = llm.isLoaded
            ? 'Engine OK — a model is already loaded.'
            : 'Engine OK — it started fine, no model loaded yet.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _engineStatus = 'Engine failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clawzilla')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You made it in.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                AppPageRoute(builder: (_) => const MainScreen()),
              ),
              child: const Text('Open the app'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _testEngine,
              child: const Text('Test engine'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _loadStartupLog,
              child: const Text('Show startup log'),
            ),
            if (_engineStatus != null) ...[
              const SizedBox(height: 12),
              Text(_engineStatus!, textAlign: TextAlign.center),
            ],
            if (_startupLog != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Startup log:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(_startupLog!, style: const TextStyle(fontSize: 12)),
            ],
            if (_crashLog != null) ...[
              const SizedBox(height: 20),
              const Text(
                'Last crash log:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(_crashLog!, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The animated page indicator.
///
/// Width, not colour, is the active signal: at 8dp wide the three dots read as
/// a row of dots regardless of colour, and the elongation is what actually
/// marks the current page.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.activeColor,
    required this.inactiveColor,
  });

  final int count;
  final int index;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: active ? 22 : 8,
          decoration: BoxDecoration(
            color: active ? activeColor : inactiveColor,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _Slide extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Slide({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // One accent moment on the first slide only would be arbitrary;
            // instead the emblem carries the brand colour and the glyph inside
            // it carries the step's meaning, which differs per slide.
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.30),
                  width: 1.5,
                ),
              ),
              child: Icon(icon, size: 38, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 28),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 14),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
