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
///
/// Build #125 (Piece A of the general browser agent): the driver also
/// carries the agent's general primitives — `navigateTo`, `snapshotPage`,
/// `clickRef`, `fillRef`, `scrollPage`, `readPageText`. Same rules: the
/// allowlist is enforced here, passwords are never filled, and every
/// step verifies itself. The six tools and the loop that drives them
/// are later pieces; this build is the driver only.
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

/// The outcome of one `navigateTo` call.
class BrowserNavigateResult {
  const BrowserNavigateResult({
    required this.ok,
    required this.message,
    this.url,
    this.title,
  });

  final bool ok;

  /// Human-readable explanation — what happened, or why it stopped.
  final String message;

  /// The URL the browser actually landed on, when [ok].
  final String? url;

  /// The page title, when [ok].
  final String? title;
}

/// The outcome of one `clickRef` call.
class BrowserClickResult {
  const BrowserClickResult({
    required this.ok,
    required this.message,
    this.label,
    this.mutating = false,
  });

  final bool ok;

  /// Human-readable explanation — what happened, or why it stopped.
  final String message;

  /// The visible text of the element that was clicked, when [ok].
  final String? label;

  /// True when the clicked element's label looks like a state-changing
  /// action (submit / buy / pay / post / send / checkout). The loop
  /// (Piece C) asks Aaron before acting on one of these; the driver
  /// only reports it.
  final bool mutating;
}

/// The outcome of one `fillRef` call.
class BrowserFillResult {
  const BrowserFillResult({
    required this.ok,
    required this.message,
    this.value,
  });

  final bool ok;

  /// Human-readable explanation — what happened, or why it stopped.
  final String message;

  /// The value that stuck in the field, when [ok].
  final String? value;
}

/// The outcome of one `scrollPage` call.
class BrowserScrollResult {
  const BrowserScrollResult({
    required this.ok,
    required this.message,
    this.scrollY = 0,
    this.maxScrollY = 0,
  });

  final bool ok;

  /// Human-readable explanation — what happened, or why it stopped.
  final String message;

  /// Vertical scroll position after the scroll, in CSS pixels.
  final int scrollY;

  /// Furthest the page can scroll, in CSS pixels.
  final int maxScrollY;
}

/// One element in a page snapshot.
///
/// Refs are stable for one snapshot only: a later snapshot re-numbers
/// from 1. `clickRef` / `fillRef` act on the latest snapshot's refs.
class BrowserSnapshotElement {
  const BrowserSnapshotElement({
    required this.ref,
    required this.kind,
    required this.label,
    this.mutating = false,
  });

  /// The short number the model uses to refer to this element.
  final int ref;

  /// One of 'heading', 'input', 'password', 'select', 'button', 'link'.
  final String kind;

  /// Visible text, or aria-label / placeholder when there is none.
  final String label;

  /// True when [label] looks like a state-changing action.
  final bool mutating;

  static BrowserSnapshotElement fromJson(Map<String, dynamic> json) {
    final label = json['label'] as String? ?? '';
    return BrowserSnapshotElement(
      ref: json['ref'] as int? ?? 0,
      kind: json['kind'] as String? ?? 'button',
      label: label,
      mutating: BrowserDriver.isMutatingLabel(label),
    );
  }
}

/// A compact, numbered view of the current page — what the model sees.
///
/// Built from the snapshot JS (viewport-scoped, capped at 60 elements)
/// and formatted by [format] into the text the loop feeds the model.
/// Only the latest snapshot is kept; older ones drop out, so the token
/// budget stays flat across steps.
class BrowserSnapshot {
  const BrowserSnapshot({
    required this.title,
    required this.url,
    required this.elements,
    required this.dropped,
    this.step = 1,
    this.totalSteps = 10,
  });

  /// Maximum elements [format] ever renders. The snapshot JS caps at
  /// the same number; this is the belt-and-braces side.
  static const int maxElements = 60;

  final String title;
  final String url;
  final List<BrowserSnapshotElement> elements;

  /// Elements the snapshot JS left out (over the cap, chrome dropped
  /// first). Added to any over-cap cut [format] makes itself.
  final int dropped;

  /// Step number within the task, 1-based.
  final int step;

  /// The loop's step cap.
  final int totalSteps;

  BrowserSnapshotElement? elementByRef(int ref) {
    for (final element in elements) {
      if (element.ref == ref) return element;
    }
    return null;
  }

  /// A short fingerprint of the page state (URL + element list). The
  /// loop (Piece C) uses it for stuck detection: same fingerprint
  /// after an action means nothing changed.
  String get fingerprint => Object.hashAll([
        url,
        for (final e in elements) '${e.ref}:${e.kind}:${e.label}',
      ]).toString();

  /// The snapshot as the model reads it: a header line, then the
  /// numbered elements grouped by kind, then a note when something
  /// was cut. The URL is always in the header so the model notices
  /// a redirect.
  String format() {
    final buffer = StringBuffer();
    buffer.writeln(
      'Page: ${title.isEmpty ? '(no title)' : title} — $url '
      '(step $step of $totalSteps)',
    );
    final shown = elements.take(maxElements).toList();
    final hidden = elements.length - shown.length + dropped;
    void group(String heading, List<BrowserSnapshotElement> items) {
      if (items.isEmpty) return;
      buffer.writeln('$heading:');
      for (final element in items) {
        buffer.write('  [${element.ref}] ${element.kind} "${element.label}"');
        if (element.kind == 'password') {
          buffer.write(' (password — never fill)');
        } else if (element.mutating) {
          buffer.write(' (confirm before using)');
        }
        buffer.writeln();
      }
    }

    group(
      'Headings',
      shown.where((e) => e.kind == 'heading').toList(),
    );
    group(
      'Inputs',
      shown
          .where(
            (e) =>
                e.kind == 'input' ||
                e.kind == 'password' ||
                e.kind == 'select',
          )
          .toList(),
    );
    group(
      'Buttons and links',
      shown
          .where((e) => e.kind == 'button' || e.kind == 'link')
          .toList(),
    );
    if (shown.isEmpty) {
      buffer.writeln('No buttons, links, or inputs on this page.');
    }
    if (hidden > 0) {
      buffer.writeln(
        '+ $hidden more element${hidden == 1 ? '' : 's'} below — '
        'scroll to see them.',
      );
    }
    return buffer.toString().trimRight();
  }
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

  /// Button labels that look like a state-changing action. A snapshot
  /// marks such elements so the loop (Piece C) can ask Aaron before
  /// acting on one. A heuristic, not a guarantee — a "Continue" button
  /// that submits an order will not match, and the visible Browser tab
  /// plus Stop are the backstop (plan §8).
  static const Set<String> mutatingLabelPatterns = {
    'submit',
    'buy',
    'pay',
    'post',
    'send',
    'checkout',
  };

  static bool isMutatingLabel(String label) {
    final lower = label.toLowerCase();
    return mutatingLabelPatterns.any(lower.contains);
  }

  /// Site names the `generate_on_site` tool accepts.
  static const Set<String> allowedSites = {'artistly', 'videoexpress'};

  WebViewController? _controller;

  /// The latest snapshot, for ref validation in [clickRef] / [fillRef].
  /// Null until the first snapshot is taken.
  BrowserSnapshot? _lastSnapshot;

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
    _lastSnapshot = null;
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

  Future<String?> _pageTitle() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller.getTitle();
    } catch (e) {
      Log.w('BrowserDriver.getTitle failed: $e');
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

  /// Loads [rawUrl] in the in-app browser — the general agent's
  /// navigation step (plan §2, Piece A).
  ///
  /// Refuses before anything loads when the URL is not http(s) or its
  /// host is not on [allowedHosts], and refuses after the load when
  /// the browser landed somewhere off-allowlist (a redirect). A bare
  /// domain gains `https://`. Returns the landed URL and page title.
  Future<BrowserNavigateResult> navigateTo(
    String rawUrl, {
    Duration pageLoadTimeout = const Duration(seconds: 30),
  }) async {
    final controller = _controller;
    if (controller == null) {
      return const BrowserNavigateResult(
        ok: false,
        message:
            'The browser tab is not ready yet — open the Browser tab once, '
            'then ask again.',
      );
    }
    final text = rawUrl.trim();
    if (text.isEmpty) {
      return const BrowserNavigateResult(
        ok: false,
        message: 'No web address was given — nothing to open.',
      );
    }
    var uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme) {
      uri = Uri.tryParse('https://$text');
    }
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return BrowserNavigateResult(
        ok: false,
        message: '"$rawUrl" is not a web address Cypher can open.',
      );
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty || !isAllowedHost(host)) {
      return BrowserNavigateResult(
        ok: false,
        message:
            '"$host" is not on the list of sites Cypher may drive yet — '
            'nothing was opened.',
      );
    }

    // Arm the wait BEFORE the load so the page-finished event cannot
    // slip past it (same pattern as generateOnArtistly).
    final loadWait = waitForNextPageFinished(timeout: pageLoadTimeout);
    try {
      await controller.loadRequest(uri);
    } catch (e) {
      return BrowserNavigateResult(
        ok: false,
        message: 'Could not open $uri in the browser: $e',
      );
    }
    if (!await loadWait) {
      return BrowserNavigateResult(
        ok: false,
        message:
            '$uri did not finish loading within '
            '${pageLoadTimeout.inSeconds}s — nothing was opened.',
      );
    }
    final url = await currentUrl();
    final landedHost = Uri.tryParse(url ?? '')?.host ?? '';
    if (!isAllowedHost(landedHost)) {
      return BrowserNavigateResult(
        ok: false,
        message:
            'The browser landed on "$url" instead of staying on an '
            'allowed site — nothing was opened.',
      );
    }
    return BrowserNavigateResult(
      ok: true,
      message: 'Opened ${url ?? uri.toString()}.',
      url: url,
      title: await _pageTitle(),
    );
  }

  /// Snapshots the current page as numbered elements — what the model
  /// sees (plan §3, Piece A).
  ///
  /// Returns null when there is no controller or the page could not be
  /// read. The snapshot is kept as [_lastSnapshot] so [clickRef] and
  /// [fillRef] can validate refs against it. Refs are stable for this
  /// snapshot only.
  Future<BrowserSnapshot?> snapshotPage({
    int step = 1,
    int totalSteps = 10,
  }) async {
    if (_controller == null) return null;
    final decoded = await evalJson(_snapshotJs);
    if (decoded == null || decoded['kind'] != 'snapshot') return null;
    final elements = ((decoded['elements'] as List<dynamic>?) ?? [])
        .whereType<Map<String, dynamic>>()
        .map(BrowserSnapshotElement.fromJson)
        .toList();
    final snapshot = BrowserSnapshot(
      title: decoded['title'] as String? ?? '',
      url: decoded['url'] as String? ?? '',
      elements: elements,
      dropped: decoded['dropped'] as int? ?? 0,
      step: step,
      totalSteps: totalSteps,
    );
    _lastSnapshot = snapshot;
    return snapshot;
  }

  /// Clicks the element numbered [ref] in the latest snapshot (plan
  /// §2, Piece A). Verifies the ref exists, is clickable, and is
  /// still there before clicking; a ref that is gone (the page
  /// changed under it) fails honestly. Headings and inputs are not
  /// clickable. The result says whether the element looks mutating.
  Future<BrowserClickResult> clickRef(int ref) async {
    if (_controller == null) {
      return const BrowserClickResult(
        ok: false,
        message:
            'The browser tab is not ready yet — open the Browser tab once, '
            'then ask again.',
      );
    }
    BrowserSnapshotElement? element = _lastSnapshot?.elementByRef(ref);
    if (_lastSnapshot != null && element == null) {
      return BrowserClickResult(
        ok: false,
        message:
            'No element [$ref] in the latest snapshot — take a fresh '
            'snapshot and try again.',
      );
    }
    if (element != null &&
        element.kind != 'button' &&
        element.kind != 'link') {
      return BrowserClickResult(
        ok: false,
        message:
            'Element [$ref] ("${element.label}") is a ${element.kind}, '
            'not something to click.',
      );
    }
    final decoded = await evalJson(_clickByRefJs(ref));
    if (decoded == null || decoded['kind'] != 'click') {
      return const BrowserClickResult(
        ok: false,
        message:
            'Could not read the page — its layout may have changed. '
            'Nothing was clicked.',
      );
    }
    if (decoded['clicked'] != true) {
      return BrowserClickResult(
        ok: false,
        message:
            'Could not click [$ref]: '
            '${decoded['reason'] ?? 'the element is gone or not clickable'}.',
      );
    }
    final label = decoded['text'] as String? ?? element?.label ?? '';
    return BrowserClickResult(
      ok: true,
      message: 'Clicked "$label".',
      label: label,
      mutating: element?.mutating ?? isMutatingLabel(label),
    );
  }

  /// Fills the field numbered [ref] in the latest snapshot with
  /// [text] (plan §2, Piece A).
  ///
  /// Uses the native value setter + input/change events, the same
  /// technique as `_fillPromptJs`, so React-style pages pick the
  /// change up — and verifies the value stuck. A password field is
  /// refused outright, in Dart and in the page script: Cypher never
  /// fills passwords.
  Future<BrowserFillResult> fillRef(int ref, String text) async {
    if (_controller == null) {
      return const BrowserFillResult(
        ok: false,
        message:
            'The browser tab is not ready yet — open the Browser tab once, '
            'then ask again.',
      );
    }
    if (text.isEmpty) {
      return const BrowserFillResult(
        ok: false,
        message: 'Nothing to fill in — the text was empty.',
      );
    }
    final element = _lastSnapshot?.elementByRef(ref);
    if (_lastSnapshot != null && element == null) {
      return BrowserFillResult(
        ok: false,
        message:
            'No element [$ref] in the latest snapshot — take a fresh '
            'snapshot and try again.',
      );
    }
    if (element != null && element.kind == 'password') {
      return const BrowserFillResult(
        ok: false,
        message:
            'That is a password field — Cypher never fills passwords.',
      );
    }
    if (element != null &&
        element.kind != 'input' &&
        element.kind != 'select') {
      return BrowserFillResult(
        ok: false,
        message:
            'Element [$ref] ("${element.label}") is a ${element.kind}, '
            'not a field to fill in.',
      );
    }
    final decoded = await evalJson(_fillByRefJs(ref, text));
    if (decoded == null || decoded['kind'] != 'fill') {
      return const BrowserFillResult(
        ok: false,
        message:
            'Could not read the page — its layout may have changed. '
            'Nothing was filled in.',
      );
    }
    if (decoded['refused'] == 'password') {
      return const BrowserFillResult(
        ok: false,
        message: 'That is a password field — Cypher never fills passwords.',
      );
    }
    if (decoded['refused'] != null) {
      return BrowserFillResult(
        ok: false,
        message:
            'Element [$ref] cannot be filled in (${decoded['refused']}).',
      );
    }
    if (decoded['found'] != true) {
      return BrowserFillResult(
        ok: false,
        message:
            'Element [$ref] is gone — take a fresh snapshot and try again.',
      );
    }
    final value = decoded['value'] as String? ?? '';
    if (value.trim() != text.trim()) {
      return const BrowserFillResult(
        ok: false,
        message:
            'The text did not stick in the field — nothing was filled in. '
            'Try again.',
      );
    }
    return BrowserFillResult(
      ok: true,
      message: 'Filled element [$ref].',
      value: value,
    );
  }

  /// Scrolls the page so more of it enters the snapshot's viewport
  /// (plan §2, Piece A). [direction] is "down" or "up"; [amount] is
  /// CSS pixels, defaulting to one viewport height.
  Future<BrowserScrollResult> scrollPage({
    required String direction,
    int? amount,
  }) async {
    if (_controller == null) {
      return const BrowserScrollResult(
        ok: false,
        message:
            'The browser tab is not ready yet — open the Browser tab once, '
            'then ask again.',
      );
    }
    final dir = direction.toLowerCase();
    if (dir != 'down' && dir != 'up') {
      return BrowserScrollResult(
        ok: false,
        message:
            'Scroll direction must be "down" or "up", not "$direction".',
      );
    }
    if (amount != null && amount <= 0) {
      return const BrowserScrollResult(
        ok: false,
        message: 'Scroll amount must be more than 0.',
      );
    }
    final decoded = await evalJson(_scrollJs(dir, amount));
    if (decoded == null || decoded['kind'] != 'scroll') {
      return const BrowserScrollResult(
        ok: false,
        message:
            'Could not scroll the page — its layout may have changed.',
      );
    }
    return BrowserScrollResult(
      ok: true,
      message: 'Scrolled $dir.',
      scrollY: decoded['scrollY'] as int? ?? 0,
      maxScrollY: decoded['maxScrollY'] as int? ?? 0,
    );
  }

  /// Returns the page's visible text (headings + paragraphs, no
  /// markup) for read-the-article / find-the-price jobs (plan §2,
  /// Piece A). Capped at [maxChars]; a longer page comes back cut
  /// with a note saying so. Returns null when the page could not be
  /// read.
  Future<String?> readPageText({int maxChars = 4000}) async {
    if (_controller == null) return null;
    final decoded = await evalJson(_readTextJs(maxChars));
    if (decoded == null || decoded['kind'] != 'read-text') return null;
    final text = decoded['text'] as String? ?? '';
    if (decoded['truncated'] == true) {
      return '$text\n[Text cut off after $maxChars characters.]';
    }
    return text;
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

  // ------------------------------------------------- General agent JS
  //
  // Build #125, Piece A of the general browser agent (plan §2–§3).
  // These scripts are the agent's hands: snapshot the page as numbered
  // refs, click/fill by ref, scroll, read text. Like the Artistly
  // recipe above, every selector here is UNVERIFIED against any live
  // page — they find elements by visible text and generic shapes on
  // purpose. Each script carries a `clawzilla-agent` marker so tests
  // can tell agent scripts apart from recipe scripts.

  /// UNVERIFIED: the page as numbered refs — visible elements only,
  /// viewport-scoped (plus a small margin), capped at 60. Headings,
  /// inputs, and buttons/links are collected in that order; when the
  /// page has more than the cap, elements inside footer/nav/header
  /// go first, then the tail is cut, and `dropped` says how many
  /// went. Kept elements get a `data-clawzilla-ref` attribute so
  /// click/fill-by-ref can find them again.
  static const String _snapshotJs = '''
// clawzilla-agent snapshot
(() => {
  const MAX = 60;
  const MARGIN = 200;
  const vw = window.innerWidth, vh = window.innerHeight;
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    return r.bottom >= -MARGIN && r.top <= vh + MARGIN && r.right >= -MARGIN && r.left <= vw + MARGIN;
  };
  const inChrome = (el) => !!el.closest('footer, nav, header');
  const labelOf = (el) => {
    const t = (el.textContent || '').trim().replace(/\\s+/g, ' ');
    if (t) return t.slice(0, 80);
    return ((el.getAttribute('aria-label') || el.placeholder || el.value || '').trim()).slice(0, 80);
  };
  const found = [];
  document.querySelectorAll('h1, h2, h3').forEach((el) => {
    if (visible(el)) found.push({kind: 'heading', label: labelOf(el), chrome: inChrome(el), el: el});
  });
  document.querySelectorAll('input, textarea, select').forEach((el) => {
    if (!visible(el)) return;
    const tag = el.tagName.toLowerCase();
    if (tag === 'input' && (el.type === 'hidden' || el.type === 'submit' || el.type === 'button')) return;
    let kind = 'input';
    if (tag === 'input' && el.type === 'password') kind = 'password';
    if (tag === 'select') kind = 'select';
    found.push({kind: kind, label: labelOf(el), chrome: inChrome(el), el: el});
  });
  document.querySelectorAll('button, a[href], [role="button"], input[type="submit"], input[type="button"]').forEach((el) => {
    if (!visible(el) || el.disabled) return;
    const kind = el.tagName.toLowerCase() === 'a' ? 'link' : 'button';
    found.push({kind: kind, label: labelOf(el), chrome: inChrome(el), el: el});
  });
  let kept = found;
  let dropped = 0;
  if (found.length > MAX) {
    const nonChrome = found.filter((e) => !e.chrome);
    if (nonChrome.length >= MAX) {
      kept = nonChrome.slice(0, MAX);
    } else {
      kept = nonChrome.concat(found.filter((e) => e.chrome).slice(0, MAX - nonChrome.length));
    }
    dropped = found.length - kept.length;
  }
  const elements = kept.map((item, i) => {
    item.el.setAttribute('data-clawzilla-ref', String(i + 1));
    return {ref: i + 1, kind: item.kind, label: item.label};
  });
  return JSON.stringify({kind: 'snapshot', title: document.title, url: location.href, elements: elements, dropped: dropped});
})()
''';

  /// UNVERIFIED: clicks the element tagged [ref] by the latest
  /// snapshot. Only buttons, links, and button-role elements count;
  /// anything else (a heading, a field) is refused, not clicked.
  static String _clickByRefJs(int ref) {
    return '''
// clawzilla-agent click
((ref) => {
  const el = document.querySelector('[data-clawzilla-ref="' + ref + '"]');
  if (!el) return JSON.stringify({kind: 'click', clicked: false, reason: 'not found'});
  const tag = el.tagName.toLowerCase();
  const clickable = tag === 'button' || tag === 'a' || el.getAttribute('role') === 'button' || (tag === 'input' && (el.type === 'submit' || el.type === 'button'));
  if (!clickable) return JSON.stringify({kind: 'click', clicked: false, reason: 'not clickable'});
  if (el.disabled) return JSON.stringify({kind: 'click', clicked: false, reason: 'disabled'});
  const r = el.getBoundingClientRect();
  if (r.width === 0 || r.height === 0) return JSON.stringify({kind: 'click', clicked: false, reason: 'not visible'});
  el.click();
  return JSON.stringify({kind: 'click', clicked: true, text: (el.textContent || el.value || '').trim()});
})($ref)
''';
  }

  /// UNVERIFIED: fills the field tagged [ref] via the native value
  /// setter so React-style pages pick the change up, then fires
  /// input/change — the same technique as `_fillPromptJs`. A password
  /// field is refused outright; anything that is not a field is
  /// refused too.
  static String _fillByRefJs(int ref, String text) {
    final value = jsonEncode(text);
    return '''
// clawzilla-agent fill
((ref, text) => {
  const el = document.querySelector('[data-clawzilla-ref="' + ref + '"]');
  if (!el) return JSON.stringify({kind: 'fill', found: false});
  if (el.tagName === 'INPUT' && el.type === 'password') return JSON.stringify({kind: 'fill', found: true, refused: 'password'});
  const tag = el.tagName;
  if (tag !== 'TEXTAREA' && tag !== 'INPUT' && tag !== 'SELECT') return JSON.stringify({kind: 'fill', found: true, refused: 'not a field'});
  const proto = tag === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : tag === 'SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(proto, 'value');
  if (desc && desc.set) { desc.set.call(el, text); } else { el.value = text; }
  el.dispatchEvent(new Event('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  return JSON.stringify({kind: 'fill', found: true, value: el.value});
})($ref, $value)
''';
  }

  /// UNVERIFIED: scrolls the page by [amount] CSS pixels (default
  /// one viewport height) in [direction] ("down" or "up").
  static String _scrollJs(String direction, int? amount) {
    final dir = jsonEncode(direction);
    final amt = amount == null ? 'null' : amount.toString();
    return '''
// clawzilla-agent scroll
((direction, amount) => {
  const y = amount || window.innerHeight;
  window.scrollBy(0, direction === 'up' ? -y : y);
  return JSON.stringify({kind: 'scroll', scrolled: true, scrollY: Math.round(window.scrollY), maxScrollY: Math.round(document.documentElement.scrollHeight - window.innerHeight)});
})($dir, $amt)
''';
  }

  /// UNVERIFIED: the page's visible text — headings, paragraphs, and
  /// list items, no markup — capped at [maxChars] with a flag when
  /// the page had more.
  static String _readTextJs(int maxChars) {
    return '''
// clawzilla-agent read-text
((maxChars) => {
  const parts = [];
  document.querySelectorAll('h1, h2, h3, h4, p, li').forEach((el) => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return;
    const t = (el.textContent || '').trim().replace(/\\s+/g, ' ');
    if (t) parts.push(t);
  });
  let text = parts.join('\\n');
  let truncated = false;
  if (text.length > maxChars) { text = text.slice(0, maxChars); truncated = true; }
  return JSON.stringify({kind: 'read-text', text: text, truncated: truncated});
})($maxChars)
''';
  }
}
