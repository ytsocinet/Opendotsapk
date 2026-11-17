/// The browser driver — the bridge between Cypher's tools and the in-app
/// browser's WebView.
///
/// Build #114: until now the `WebViewController` lived privately inside
/// `BrowserScreen`'s state and nothing outside the widget could touch it.
/// This driver is the missing bridge the browser-driving scope (§3)
/// describes: `BrowserScreen` registers its controller here when the tab is
/// created, and the `generate_on_site` tool drives the page through it
/// (navigate, run JS, read results back).
///
/// Guardrails, all enforced here or in the registry — never in the model:
/// * Only Artistly and VideoExpress, by host allowlist. Anything else is
///   refused before anything loads.
/// * Acts inside Aaron's already-signed-in session. The driver never sees,
///   stores, types, or reads a username, password, or session cookie. If
///   the page is a login wall, the recipe stops and tells Aaron to sign
///   in himself.
/// * Every step verifies itself before the next one runs (element found?
///   button enabled? result actually appeared?). A step that fails reports
///   failure honestly — never a fake success.
///
/// DOM gap (honest): the Artistly logged-in generation page's real DOM was
/// never observable from here — the app page is a JS app behind a login,
/// and the public login page returns no extractable content. The recipe
/// below therefore finds elements by visible text and generic shapes
/// (largest visible textarea, a button whose text starts with "Generate")
/// rather than by ids or class names that were never seen. Every selector
/// in this file is marked UNVERIFIED, and the on-phone test is the
/// settling test: if Artistly's page does not match, the tool fails
/// loudly naming the step, and the selectors get fixed from the real page.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/utils/log.dart';

/// What a generation attempt ended as.
enum BrowserGenerationStatus {
  /// The result appeared and its URL(s) came back.
  ready,

  /// Generation started, but no result appeared within the poll cap.
  /// Not a failure — the generation may still finish in the browser.
  generating,

  /// Something stopped the attempt before (or without) generating.
  failed,
}

/// The outcome of one `generate_on_site` run.
class BrowserGenerationResult {
  const BrowserGenerationResult({
    required this.status,
    required this.message,
    this.urls = const [],
  });

  final BrowserGenerationStatus status;

  /// Human-readable explanation — what happened, or why it stopped.
  final String message;

  /// Generated media URLs, only when [status] is [BrowserGenerationStatus.ready].
  final List<String> urls;

  bool get isReady => status == BrowserGenerationStatus.ready;
}

/// Drives the in-app browser's WebView for Cypher's tools.
///
/// Singleton: there is one browser tab and one controller per app launch
/// (all tabs stay mounted, so the controller effectively lives once per
/// run). `BrowserScreen` registers the controller in `initState`,
/// unregisters it in `dispose`, and forwards `onPageFinished` here.
class BrowserDriver {
  static final BrowserDriver _instance = BrowserDriver._internal();
  factory BrowserDriver() => _instance;
  BrowserDriver._internal();

  static BrowserDriver get instance => _instance;

  /// The Artistly app root. A signed-in visit lands on the dashboard; a
  /// signed-out one lands on the login page, which the recipe detects.
  static const String artistlyAppUrl = 'https://app.artistly.ai/';

  /// VideoExpress app root. Recipe not built yet (build #114 is Artistly
  /// images first); the registry refuses it until the recipe lands.
  static const String videoExpressAppUrl = 'https://app.videoexpress.ai/';

  /// Hosts Cypher may ever drive. Anything else is refused at execution
  /// time, even if the model asks for it.
  static const Set<String> allowedHosts = {
    'app.artistly.ai',
    'app.videoexpress.ai',
  };

  static bool isAllowedHost(String host) =>
      allowedHosts.contains(host.toLowerCase());

  /// Site names the `generate_on_site` tool accepts.
  static const Set<String> allowedSites = {'artistly', 'videoexpress'};

  WebViewController? _controller;

  /// Page-finished events, in order. The recipe snapshots the count
  /// before navigating and waits for it to rise — race-free, unlike
  /// waiting for "the" finish event after the load already started.
  int _finishedCount = 0;
  final StreamController<int> _finishedController =
      StreamController<int>.broadcast();

  /// Messages posted by pages through the `Clawzilla` JS channel.
  /// V1 recipes poll with `runJavaScriptReturningResult`; the channel is
  /// the push path for later recipes (e.g. a result-ready observer).
  final StreamController<String> _channelController =
      StreamController<String>.broadcast();

  /// The latest channel message, if any.
  String? lastChannelMessage;

  Stream<String> get channelMessages => _channelController.stream;

  @visibleForTesting
  void resetForTest() {
    _controller = null;
    lastChannelMessage = null;
  }

  void registerController(WebViewController controller) {
    _controller = controller;
  }

  void unregisterController(WebViewController controller) {
    if (identical(_controller, controller)) _controller = null;
  }

  bool get hasController => _controller != null;

  /// Called by `BrowserScreen`'s `onPageFinished`.
  void notifyPageFinished(String url) {
    _finishedCount++;
    _finishedController.add(_finishedCount);
  }

  /// Called by the `Clawzilla` JS channel in `BrowserScreen`.
  void onChannelMessage(String message) {
    lastChannelMessage = message;
    _channelController.add(message);
  }

  /// Waits for the next page-finished event after this call. Returns
  /// false on timeout instead of throwing — the caller reports it.
  Future<bool> waitForNextPageFinished({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final before = _finishedCount;
    try {
      await _finishedController.stream
          .firstWhere((count) => count > before)
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<String?> currentUrl() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller.currentUrl();
    } catch (e) {
      Log.w('BrowserDriver.currentUrl failed: $e');
      return null;
    }
  }

  Future<Object?> runJavaScriptReturningResult(String script) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('BrowserDriver has no WebViewController registered.');
    }
    return controller.runJavaScriptReturningResult(script);
  }

  Future<void> runJavaScript(String script) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError('BrowserDriver has no WebViewController registered.');
    }
    return controller.runJavaScript(script);
  }

  /// Runs [script] and decodes its JSON-string result into a map.
  ///
  /// Every recipe script returns `JSON.stringify({...})`, so a String
  /// result is the expected shape. Anything else (a throw, a non-JSON
  /// value, a null) is a failed read, not a value — the caller reports
  /// it instead of guessing.
  Future<Map<String, dynamic>?> evalJson(String script) async {
    try {
      final raw = await runJavaScriptReturningResult(script);
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (e) {
      Log.w('BrowserDriver.evalJson failed: $e');
      return null;
    }
  }

  /// Polls [script] until it reports `{"ok": true}`, or [timeout].
  /// Returns the last decoded map, or null when nothing ever decoded.
  Future<Map<String, dynamic>?> waitForJson(
    String script, {
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Map<String, dynamic>? last;
    while (DateTime.now().isBefore(deadline)) {
      last = await evalJson(script);
      if (last != null && last['ok'] == true) return last;
      await Future.delayed(interval);
    }
    return last;
  }

  /// Generates one image on Artistly, end to end, inside the browser.
  ///
  /// Steps (each verified before the next runs): open the app → wait for
  /// the load → refuse a login wall → open the Fast AI Image Designer →
  /// fill the prompt → click generate → poll for fresh result images
  /// with a firm cap. A step that fails returns [failed] naming the
  /// step; a generation still running at the cap returns [generating],
  /// never a hang.
  ///
  /// [pollCap] bounds the whole wait for a result; [pollInterval] is the
  /// gap between result checks. Both are parameters (with production
  /// defaults) so tests can run the recipe without waiting out the cap.
  Future<BrowserGenerationResult> generateOnArtistly({
    required String prompt,
    Duration pageLoadTimeout = const Duration(seconds: 30),
    Duration stepTimeout = const Duration(seconds: 10),
    Duration pollCap = const Duration(seconds: 45),
    Duration pollInterval = const Duration(seconds: 5),
  }) async {
    final controller = _controller;
    if (controller == null) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'The browser tab is not ready yet — open the Browser tab once, '
            'then ask again.',
      );
    }

    // 1. Open the app. The wait is armed BEFORE the load so the
    // page-finished event cannot slip past it.
    final loadWait =
        waitForNextPageFinished(timeout: pageLoadTimeout);
    try {
      await controller.loadRequest(Uri.parse(artistlyAppUrl));
    } catch (e) {
      return BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message: 'Could not open Artistly in the browser: $e',
      );
    }
    if (!await loadWait) {
      return BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'Artistly did not finish loading within '
            '${pageLoadTimeout.inSeconds}s — nothing was generated. '
            'Check the browser tab and try again.',
      );
    }

    // 2. The page must still be on Artistly. A redirect off-site (or a
    // login flow on another host) stops the run before anything is
    // clicked.
    final url = await currentUrl();
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    if (!isAllowedHost(host)) {
      return BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'Artistly sent the browser to "$url" instead of staying on '
            'app.artistly.ai — nothing was generated. Open the Artistly '
            'chip and sign in, then ask again.',
      );
    }

    // 3. Login wall? A password field means signed out. Never type
    // credentials — stop and say so.
    final login = await evalJson(_loginCheckJs);
    if (login == null) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'Could not read the Artistly page — its layout may have '
            'changed. Nothing was generated.',
      );
    }
    if (login['loginWall'] == true) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'You are signed out of Artistly in the browser — sign in '
            'first (tap the Artistly chip), then ask again. Nothing was '
            'generated, and Cypher never touches your password.',
      );
    }

    // 4. Get to the Fast AI Image Designer. The dashboard's "Create
    // Design" button opens the designer choice; the Fast designer is
    // the quick generation flow. If the prompt box is already on the
    // page (a direct generation view), skip straight to it.
    var hasPrompt =
        (await evalJson(_promptFieldPresentJs))?['found'] == true;
    if (!hasPrompt) {
      if (login['hasCreateDesign'] != true) {
        return const BrowserGenerationResult(
          status: BrowserGenerationStatus.failed,
          message:
              'Could not find the "Create Design" button on Artistly — '
              'its page may have changed. Nothing was generated.',
        );
      }
      final clicked = await evalJson(
        _clickByTextJs('Create Design'),
      );
      if (clicked?['clicked'] != true) {
        return const BrowserGenerationResult(
          status: BrowserGenerationStatus.failed,
          message:
              'Could not tap "Create Design" on Artistly — its page may '
              'have changed. Nothing was generated.',
        );
      }
      final designer = await waitForJson(
        _designerChoiceJs,
        timeout: stepTimeout,
      );
      if (designer == null || designer['ok'] != true) {
        return const BrowserGenerationResult(
          status: BrowserGenerationStatus.failed,
          message:
              'Artistly did not show the designer choice after "Create '
              'Design" — its page may have changed. Nothing was '
              'generated.',
        );
      }
      if (designer['hasFastDesigner'] == true) {
        final fast = await evalJson(
          _clickByTextJs('Fast AI Image Designer'),
        );
        if (fast?['clicked'] != true) {
          return const BrowserGenerationResult(
            status: BrowserGenerationStatus.failed,
            message:
                'Could not open the Fast AI Image Designer — its page '
                'may have changed. Nothing was generated.',
          );
        }
      }
      final promptAppeared = await waitForJson(
        _promptFieldPresentJs,
        timeout: stepTimeout,
      );
      hasPrompt = promptAppeared?['found'] == true;
      if (!hasPrompt) {
        return const BrowserGenerationResult(
          status: BrowserGenerationStatus.failed,
          message:
              'Artistly did not show a prompt box — its page may have '
              'changed. Nothing was generated.',
        );
      }
    }

    // 5. Snapshot the images already on the page, so the poll only
    // reports images this generation produced.
    final before =
        (await evalJson(_listImagesJs))?['urls'] as List<dynamic>? ?? [];

    // 6. Fill the prompt. The native value setter + input/change events
    // are what React-style pages listen for — assigning `.value`
    // directly would leave the app's own state empty.
    final filled = await evalJson(_fillPromptJs(prompt));
    if (filled == null || filled['found'] != true) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'Could not find the prompt box on Artistly — its page may '
            'have changed. Nothing was generated.',
      );
    }
    final filledValue = filled['value'] as String? ?? '';
    if (!filledValue.contains(prompt.trim())) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'The prompt did not stick in Artistly\'s prompt box — '
            'nothing was generated. Try again.',
      );
    }

    // 7. Generate. Only an enabled button whose text starts with
    // "Generate" counts; "Regenerate" is excluded, so a retry button
    // can never be mistaken for the generate button.
    final generated = await evalJson(_clickByTextJs('Generate'));
    if (generated?['clicked'] != true) {
      return const BrowserGenerationResult(
        status: BrowserGenerationStatus.failed,
        message:
            'Could not find the Generate button on Artistly — its page '
            'may have changed. Nothing was generated.',
      );
    }

    // 8. Poll for fresh result images, with a firm cap. A slow
    // generation reports "still generating" instead of hanging the turn.
    final deadline = DateTime.now().add(pollCap);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      final found = await evalJson(_freshImagesJs(before));
      final urls = (found?['urls'] as List<dynamic>?)
              ?.whereType<String>()
              // Belt and braces: the page script already filters out
              // pre-existing images, but the recipe's contract is that
              // only fresh results are reported, so filter here too.
              .where((url) => !before.contains(url))
              .toList() ??
          [];
      if (urls.isNotEmpty) {
        return BrowserGenerationResult(
          status: BrowserGenerationStatus.ready,
          message:
              'Generated ${urls.length} image(s) on Artistly.',
          urls: urls,
        );
      }
    }
    return const BrowserGenerationResult(
      status: BrowserGenerationStatus.generating,
      message:
          'Started generating on Artistly — it is still working. Check '
          'the Browser tab for the result; it will also be in your '
          'Artistly library.',
    );
  }

  // ---------------------------------------------------------------- JS
  //
  // Every script below returns JSON.stringify({...}) and every selector
  // is UNVERIFIED — no live DOM evidence exists for Artistly's logged-in
  // pages (see the file header). They find elements by visible text and
  // generic shapes on purpose: an id or class name that was never seen
  // would be a guess dressed up as knowledge.

  /// UNVERIFIED: a password field means a login wall; "Create Design"
  /// is the dashboard button the Artistly walkthroughs describe.
  static const String _loginCheckJs = '''
(() => {
  const pw = document.querySelector('input[type="password"]');
  const hasCreateDesign = Array.from(document.querySelectorAll('button, a, [role="button"]')).some((el) => {
    const t = (el.textContent || '').trim().toLowerCase();
    return t === 'create design' || t.indexOf('create design') === 0;
  });
  return JSON.stringify({loginWall: !!pw, hasCreateDesign: hasCreateDesign});
})()
''';

  /// UNVERIFIED: the prompt box is the largest visible textarea, or a
  /// text input whose placeholder/aria-label talks about a prompt.
  static const String _promptFieldPresentJs = '''
(() => {
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  };
  const tas = Array.from(document.querySelectorAll('textarea')).filter(visible);
  if (tas.length > 0) return JSON.stringify({ok: true, found: true});
  const inputs = Array.from(document.querySelectorAll('input[type="text"], input:not([type])')).filter((i) => {
    if (!visible(i)) return false;
    const hay = ((i.placeholder || '') + ' ' + (i.getAttribute('aria-label') || '')).toLowerCase();
    return /prompt|describe|keyword|imagine|design/i.test(hay);
  });
  return JSON.stringify({ok: inputs.length > 0, found: inputs.length > 0});
})()
''';

  /// UNVERIFIED: after "Create Design", the designer choice offers the
  /// Fast AI Image Designer; a page that already has a prompt box
  /// reports ok without it.
  static const String _designerChoiceJs = '''
(() => {
  const text = (el) => (el.textContent || '').trim().toLowerCase();
  const els = Array.from(document.querySelectorAll('button, a, [role="button"]'));
  const hasFast = els.some((el) => {
    const t = text(el);
    return t === 'fast ai image designer' || t.indexOf('fast ai image designer') === 0;
  });
  const hasPrompt = !!document.querySelector('textarea');
  return JSON.stringify({ok: hasFast || hasPrompt, hasFastDesigner: hasFast});
})()
''';

  /// UNVERIFIED: clicks the first enabled, visible button/link whose
  /// visible text equals [label] or starts with it. "Regenerate" is
  /// excluded so it can never stand in for "Generate".
  static String _clickByTextJs(String label) {
    final want = jsonEncode(label.toLowerCase());
    return '''
((label) => {
  const els = Array.from(document.querySelectorAll('button, a, [role="button"], input[type="submit"], input[type="button"]'));
  const match = els.find((el) => {
    if (el.disabled) return false;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    const text = ((el.textContent || el.value || '').trim()).toLowerCase();
    if (text.indexOf('regenerate') !== -1) return false;
    return text === label || text.indexOf(label) === 0;
  });
  if (!match) return JSON.stringify({clicked: false});
  match.click();
  return JSON.stringify({clicked: true, text: (match.textContent || match.value || '').trim()});
})($want)
''';
  }

  /// UNVERIFIED: fills the prompt box via the native value setter so
  /// React-style pages pick the change up, then fires input/change.
  static String _fillPromptJs(String prompt) {
    final value = jsonEncode(prompt);
    return '''
((prompt) => {
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none';
  };
  const tas = Array.from(document.querySelectorAll('textarea')).filter(visible);
  tas.sort((a, b) => (b.getBoundingClientRect().width * b.getBoundingClientRect().height) - (a.getBoundingClientRect().width * a.getBoundingClientRect().height));
  let el = tas[0] || null;
  if (!el) {
    const inputs = Array.from(document.querySelectorAll('input[type="text"], input:not([type])')).filter((i) => {
      if (!visible(i)) return false;
      const hay = ((i.placeholder || '') + ' ' + (i.getAttribute('aria-label') || '')).toLowerCase();
      return /prompt|describe|keyword|imagine|design/i.test(hay);
    });
    el = inputs[0] || null;
  }
  if (!el) return JSON.stringify({found: false});
  const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(proto, 'value');
  if (desc && desc.set) { desc.set.call(el, prompt); } else { el.value = prompt; }
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return JSON.stringify({found: true, value: el.value});
})($value)
''';
  }

  /// All http(s) image URLs currently on the page.
  static const String _listImagesJs = '''
(() => {
  const urls = [];
  for (const img of document.images) {
    const src = img.currentSrc || img.src || '';
    if (src.indexOf('http') === 0) urls.push(src);
  }
  return JSON.stringify({urls: urls});
})()
''';

  /// UNVERIFIED: images that appeared after [before] — http(s), big
  /// enough to be a result, and not a logo/icon/avatar/placeholder.
  static String _freshImagesJs(List<dynamic> before) {
    final seen = jsonEncode(before);
    return '''
((before) => {
  const seen = new Set(before);
  const fresh = [];
  for (const img of document.images) {
    const src = img.currentSrc || img.src || '';
    if (src.indexOf('http') !== 0) continue;
    if (seen.has(src)) continue;
    if (/logo|icon|avatar|placeholder|spinner|loading/i.test(src)) continue;
    if (img.naturalWidth < 200 || img.naturalHeight < 200) continue;
    fresh.push(src);
  }
  return JSON.stringify({urls: fresh.slice(0, 4)});
})($seen)
''';
  }
}
