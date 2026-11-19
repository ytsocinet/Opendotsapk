/// Tests for the browser driver (build #114, #125).
///
/// The driver is the bridge between Cypher's tools and the in-app
/// browser's WebView. There is no Android SDK on this VM, so the
/// tests run against a scripted fake WebView platform: the fake records
/// every load and JS evaluation, and a per-test page model answers the
/// driver's JS probes the way a real page would.
///
/// Build #114 covered the `generate_on_site` recipe (logged in or
/// logged out, designer shown or not, results appearing or never
/// appearing). Build #125 (Piece A of the general browser agent)
/// covers the general primitives — navigate, snapshot, click/fill by
/// ref, scroll, read text — against a second scripted page,
/// `ScriptedAgentPage`. Scripts carrying the `clawzilla-agent`
/// marker are routed to it; recipe scripts go to `ScriptedArtistlyPage`.
///
/// What the tests prove: the primitives' flow, the allowlist, honest
/// failures (missing ref, disabled element, password refusal, a value
/// that does not stick), and the snapshot's shape (numbered refs,
/// mutating markers, the 60-element cap in the formatted text).
/// What they cannot prove: that a real page's DOM matches the
/// text-based selectors the driver uses — every selector in the
/// driver is UNVERIFIED against live pages, and the on-phone test
/// settles that. The snapshot JS's viewport filter and chrome-first
/// cap also run in the page, not in the fake, so the fake answers
/// with a canned element list and the tests prove the Dart side
/// (formatting, ref validation, the 60-element render cap).
library;

import 'dart:async';
import 'dart:convert';

import 'package:clawzilla/data/services/browser_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A fake platform controller that records loads/JS and answers JS from a
/// per-test page model.
class ScriptedPlatformWebViewController extends PlatformWebViewController {
  ScriptedPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
    this.loadedUrls,
  ) : super.implementation(params);

  final List<Uri> loadedUrls;
  final List<String> scripts = [];

  /// Answers `runJavaScriptReturningResult`. Set by each test.
  Object? Function(String script)? jsHandler;

  /// What `currentUrl()` reports.
  String currentUrlValue = 'https://app.artistly.ai/';

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUrls.add(params.uri);
    // Simulate the screen's onPageFinished callback.
    unawaited(
      Future.microtask(
        () => BrowserDriver.instance.notifyPageFinished(
          params.uri.toString(),
        ),
      ),
    );
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams params,
  ) async {}

  @override
  Future<String?> getTitle() async => 'Fake page';

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<bool> canGoForward() async => false;

  @override
  Future<void> reload() async {}

  @override
  Future<String?> currentUrl() async => currentUrlValue;

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    scripts.add(javaScript);
    final handler = jsHandler;
    if (handler == null) {
      throw StateError('No jsHandler set for script: $javaScript');
    }
    final result = handler(javaScript);
    return result ?? '';
  }
}

class ScriptedPlatformNavigationDelegate extends PlatformNavigationDelegate {
  ScriptedPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) : super.implementation(params);

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback callback,
  ) async {}
}

class ScriptedPlatformWebViewWidget extends PlatformWebViewWidget {
  ScriptedPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) : super.implementation(params);

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class ScriptedWebViewPlatform extends WebViewPlatform {
  late ScriptedPlatformWebViewController lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    lastController = ScriptedPlatformWebViewController(params, []);
    return lastController;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return ScriptedPlatformNavigationDelegate(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return ScriptedPlatformWebViewWidget(params);
  }
}

/// The Artistly page as the recipe sees it, scripted per test.
class ScriptedArtistlyPage {
  bool loggedIn = true;
  bool hasCreateDesign = true;
  bool hasFastDesigner = true;

  /// The prompt box is visible only after the Fast designer opens.
  bool promptVisible = false;

  /// Images already on the page before this generation.
  List<String> beforeImages = const [];

  /// Result images, appearing after [resultAfterPolls] fresh-image polls.
  List<String> resultUrls = const [
    'https://cdn.artistly.ai/results/cover-1.png',
  ];
  int resultAfterPolls = 1;

  int _polls = 0;
  String? filledPrompt;

  String answer(String script) {
    // Login check.
    if (script.contains('loginWall')) {
      return jsonEncode({
        'loginWall': !loggedIn,
        'hasCreateDesign': loggedIn && hasCreateDesign,
      });
    }
    // Prompt fill (fires input/change events) — before the
    // prompt-present check, which shares the textarea code.
    if (script.contains("dispatchEvent(new Event('input'")) {
      if (!promptVisible) return jsonEncode({'found': false});
      filledPrompt = _promptFrom(script);
      return jsonEncode({'found': true, 'value': filledPrompt});
    }
    // Designer choice after "Create Design".
    if (script.contains('hasFastDesigner')) {
      return jsonEncode({
        'ok': hasFastDesigner || promptVisible,
        'hasFastDesigner': hasFastDesigner,
      });
    }
    // Click a button by its text.
    if (script.contains('match.click()')) {
      if (script.contains('"create design"')) {
        if (!loggedIn || !hasCreateDesign) {
          return jsonEncode({'clicked': false});
        }
        return jsonEncode({'clicked': true, 'text': 'Create Design'});
      }
      if (script.contains('"fast ai image designer"')) {
        if (!hasFastDesigner) return jsonEncode({'clicked': false});
        promptVisible = true;
        return jsonEncode({'clicked': true, 'text': 'Fast AI Image Designer'});
      }
      if (script.contains('"generate"')) {
        if (!promptVisible) return jsonEncode({'clicked': false});
        return jsonEncode({'clicked': true, 'text': 'Generate'});
      }
      return jsonEncode({'clicked': false});
    }
    // Fresh result images (the poll).
    if (script.contains('fresh.slice(0, 4)')) {
      _polls++;
      if (_polls >= resultAfterPolls) {
        return jsonEncode({'urls': resultUrls});
      }
      return jsonEncode({'urls': <String>[]});
    }
    // Existing images on the page (the "before" snapshot).
    if (script.contains('urls: urls')) {
      return jsonEncode({'urls': beforeImages});
    }
    // Prompt-box presence.
    if (script.contains('inputs.length > 0')) {
      return jsonEncode({
        'ok': promptVisible,
        'found': promptVisible,
      });
    }
    throw StateError('ScriptedArtistlyPage: unhandled script: $script');
  }

  /// The prompt is embedded in the fill script as a JSON string literal;
  /// pull it back out so the test can assert the fill carried the words.
  String? _promptFrom(String script) {
    final match = RegExp(r'\(\s*(".*")\s*\)\s*$', dotAll: true)
        .firstMatch(script.trim());
    if (match == null) return null;
    try {
      return jsonDecode(match.group(1)!) as String?;
    } catch (_) {
      return null;
    }
  }
}

/// One element on the scripted agent page (build #125).
class ScriptedAgentElement {
  ScriptedAgentElement({
    required this.kind,
    required this.label,
    this.enabled = true,
    this.visible = true,
    this.value = '',
  });

  /// 'heading', 'input', 'password', 'button', 'link', 'select'.
  final String kind;
  String label;
  bool enabled;
  bool visible;
  String value;
}

/// A generic page as the general agent primitives see it (build #125).
///
/// Refs are the element's 1-based position in [elements], matching
/// what the snapshot JS assigns. The fake does not run the JS — it
/// answers each agent script from this model.
class ScriptedAgentPage {
  String title = 'Fake Store';
  String url = 'https://app.artistly.ai/shop';
  String pageText =
      'Fake Store\nThe best fake goods.\nFree shipping over \$25.';

  /// Elements the snapshot JS left out (over its cap).
  int dropped = 0;

  int scrollY = 0;
  int maxScrollY = 1600;
  int viewportHeight = 800;

  /// When false, fills report back an unchanged value.
  bool fillSticks = true;

  List<ScriptedAgentElement> elements = [
    ScriptedAgentElement(kind: 'heading', label: 'Fake Store'),
    ScriptedAgentElement(kind: 'input', label: 'Email address'),
    ScriptedAgentElement(kind: 'password', label: 'Password'),
    ScriptedAgentElement(kind: 'button', label: 'Sign in'),
    ScriptedAgentElement(kind: 'button', label: 'Buy now — \$9.99'),
    ScriptedAgentElement(kind: 'link', label: 'About us'),
    ScriptedAgentElement(kind: 'select', label: 'Choose a size'),
    ScriptedAgentElement(kind: 'input', label: 'Leave a note'),
  ];

  String? clickedLabel;
  int? clickedRef;
  String? filledValue;
  int? filledRef;

  String answer(String script) {
    // Snapshot: canned element list, refs in list order.
    if (script.contains("kind: 'snapshot'")) {
      return jsonEncode({
        'kind': 'snapshot',
        'title': title,
        'url': url,
        'elements': [
          for (var i = 0; i < elements.length; i++)
            {
              'ref': i + 1,
              'kind': elements[i].kind,
              'label': elements[i].label,
            },
        ],
        'dropped': dropped,
      });
    }
    // Click by ref: the script ends with `})(<ref>)`.
    if (script.contains("kind: 'click'")) {
      final match =
          RegExp(r'\}\)\((\d+)\)\s*$').firstMatch(script.trim());
      final ref = int.parse(match!.group(1)!);
      if (ref < 1 || ref > elements.length) {
        return jsonEncode({
          'kind': 'click',
          'clicked': false,
          'reason': 'not found',
        });
      }
      final el = elements[ref - 1];
      if (el.kind != 'button' && el.kind != 'link') {
        return jsonEncode({
          'kind': 'click',
          'clicked': false,
          'reason': 'not clickable',
        });
      }
      if (!el.enabled) {
        return jsonEncode({
          'kind': 'click',
          'clicked': false,
          'reason': 'disabled',
        });
      }
      if (!el.visible) {
        return jsonEncode({
          'kind': 'click',
          'clicked': false,
          'reason': 'not visible',
        });
      }
      clickedRef = ref;
      clickedLabel = el.label;
      return jsonEncode({
        'kind': 'click',
        'clicked': true,
        'text': el.label,
      });
    }
    // Fill by ref: the script ends with `})(<ref>, "<text>")`.
    if (script.contains("kind: 'fill'")) {
      final match = RegExp(
        r'\}\)\(\s*(\d+)\s*,\s*("(?:[^"\\]|\\.)*")\s*\)\s*$',
      ).firstMatch(script.trim());
      final ref = int.parse(match!.group(1)!);
      final text = jsonDecode(match.group(2)!) as String;
      if (ref < 1 || ref > elements.length) {
        return jsonEncode({'kind': 'fill', 'found': false});
      }
      final el = elements[ref - 1];
      if (el.kind == 'password') {
        return jsonEncode({
          'kind': 'fill',
          'found': true,
          'refused': 'password',
        });
      }
      if (el.kind != 'input' && el.kind != 'select') {
        return jsonEncode({
          'kind': 'fill',
          'found': true,
          'refused': 'not a field',
        });
      }
      filledRef = ref;
      if (fillSticks) {
        el.value = text;
        filledValue = text;
      }
      return jsonEncode({
        'kind': 'fill',
        'found': true,
        'value': el.value,
      });
    }
    // Scroll: the script ends with `})("<direction>", <amount|null>)`.
    if (script.contains("kind: 'scroll'")) {
      final match = RegExp(
        r'\}\)\(\s*"(down|up)"\s*,\s*(\d+|null)\s*\)\s*$',
      ).firstMatch(script.trim());
      final direction = match!.group(1)!;
      final amount = match.group(2) == 'null'
          ? viewportHeight
          : int.parse(match.group(2)!);
      if (direction == 'down') {
        scrollY = (scrollY + amount).clamp(0, maxScrollY);
      } else {
        scrollY = (scrollY - amount).clamp(0, maxScrollY);
      }
      return jsonEncode({
        'kind': 'scroll',
        'scrolled': true,
        'scrollY': scrollY,
        'maxScrollY': maxScrollY,
      });
    }
    // Read text: the script ends with `})(<maxChars>)`.
    if (script.contains("kind: 'read-text'")) {
      final match =
          RegExp(r'\}\)\((\d+)\)\s*$').firstMatch(script.trim());
      final maxChars = int.parse(match!.group(1)!);
      final truncated = pageText.length > maxChars;
      final text =
          truncated ? pageText.substring(0, maxChars) : pageText;
      return jsonEncode({
        'kind': 'read-text',
        'text': text,
        'truncated': truncated,
      });
    }
    throw StateError('ScriptedAgentPage: unhandled script: $script');
  }
}

void main() {
  late ScriptedWebViewPlatform platform;
  late ScriptedArtistlyPage page;
  late ScriptedAgentPage agentPage;

  setUp(() {
    BrowserDriver.instance.resetForTest();
    platform = ScriptedWebViewPlatform();
    WebViewPlatform.instance = platform;
    page = ScriptedArtistlyPage();
    agentPage = ScriptedAgentPage();
    final controller = WebViewController();
    platform.lastController.jsHandler = (script) =>
        script.contains('clawzilla-agent')
            ? agentPage.answer(script)
            : page.answer(script);
    BrowserDriver.instance.registerController(controller);
  });

  tearDown(() {
    BrowserDriver.instance.resetForTest();
  });

  Future<BrowserGenerationResult> generate({
    Duration pollCap = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 20),
  }) {
    return BrowserDriver.instance.generateOnArtistly(
      prompt: 'a neon city skyline at dusk',
      pageLoadTimeout: const Duration(seconds: 5),
      stepTimeout: const Duration(seconds: 5),
      pollCap: pollCap,
      pollInterval: pollInterval,
    );
  }

  group('BrowserDriver registration', () {
    test('hasController is false with no controller registered', () {
      BrowserDriver.instance.resetForTest();
      expect(BrowserDriver.instance.hasController, isFalse);
    });

    test('generate without a controller fails honestly', () async {
      BrowserDriver.instance.resetForTest();
      final result = await generate();
      expect(result.status, BrowserGenerationStatus.failed);
      expect(result.message, contains('not ready'));
      expect(result.urls, isEmpty);
    });

    test('channel messages are recorded', () {
      BrowserDriver.instance.onChannelMessage('result-ready');
      expect(BrowserDriver.instance.lastChannelMessage, 'result-ready');
    });
  });

  group('BrowserDriver.generateOnArtistly', () {
    test('happy path: navigates, fills the prompt, clicks generate, '
        'returns the result URLs', () async {
      final result = await generate();

      expect(result.status, BrowserGenerationStatus.ready);
      expect(
        result.urls,
        ['https://cdn.artistly.ai/results/cover-1.png'],
      );
      // The app was opened first.
      expect(
        platform.lastController.loadedUrls,
        [Uri.parse(BrowserDriver.artistlyAppUrl)],
      );
      // The fill carried Aaron's words.
      expect(page.filledPrompt, 'a neon city skyline at dusk');
      // The recipe evaluated JS that fills the prompt and clicks
      // generate — assert on the scripts, not just the outcome. The
      // labels are lowercase in the JS source (the recipe matches on
      // lowercased button text).
      final scripts = platform.lastController.scripts.join('\n');
      expect(scripts, contains("'create design'"));
      expect(scripts, contains("'fast ai image designer'"));
      expect(scripts, contains('a neon city skyline at dusk'));
      expect(scripts, contains('match.click()'));
    });

    test('result images exclude images already on the page', () async {
      page.beforeImages = const [
        'https://cdn.artistly.ai/results/cover-1.png',
      ];
      page.resultUrls = const [
        'https://cdn.artistly.ai/results/cover-1.png',
        'https://cdn.artistly.ai/results/cover-2.png',
      ];
      final result = await generate();

      expect(result.status, BrowserGenerationStatus.ready);
      // The poll only reports fresh images, so the pre-existing
      // cover-1 is not reported twice.
      expect(result.urls, ['https://cdn.artistly.ai/results/cover-2.png']);
    });

    test('login wall stops the run and generates nothing', () async {
      page.loggedIn = false;
      final result = await generate();

      expect(result.status, BrowserGenerationStatus.failed);
      expect(result.message, contains('signed out'));
      final scripts = platform.lastController.scripts.join('\n');
      expect(scripts, isNot(contains('match.click()')));
      expect(page.filledPrompt, isNull);
    });

    test('missing Create Design button fails honestly, no click',
        () async {
      page.hasCreateDesign = false;
      final result = await generate();

      expect(result.status, BrowserGenerationStatus.failed);
      expect(result.message, contains('Create Design'));
      expect(page.filledPrompt, isNull);
    });

    test('a generation still running at the poll cap reports '
        '"still generating", never a hang', () async {
      page.resultAfterPolls = 1000000;
      final stopwatch = Stopwatch()..start();
      final result = await generate(
        pollCap: const Duration(milliseconds: 100),
        pollInterval: const Duration(milliseconds: 20),
      );
      stopwatch.stop();

      expect(result.status, BrowserGenerationStatus.generating);
      expect(result.message, contains('still working'));
      expect(result.urls, isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('redirect off Artistly refuses before anything is clicked',
        () async {
      platform.lastController.currentUrlValue =
          'https://artistly.ai/pricing';
      final result = await generate();

      expect(result.status, BrowserGenerationStatus.failed);
      expect(result.message, contains('artistly.ai/pricing'));
      expect(page.filledPrompt, isNull);
    });
  });

  group('BrowserDriver allowlist', () {
    test('Artistly and VideoExpress hosts are allowed', () {
      expect(BrowserDriver.isAllowedHost('app.artistly.ai'), isTrue);
      expect(BrowserDriver.isAllowedHost('app.videoexpress.ai'), isTrue);
    });

    test('any other host is refused', () {
      expect(BrowserDriver.isAllowedHost('youtube.com'), isFalse);
      expect(BrowserDriver.isAllowedHost('artistly.ai'), isFalse);
      expect(BrowserDriver.isAllowedHost('evil-app.artistly.ai'), isFalse);
    });
  });

  group('BrowserDriver.navigateTo (build #125)', () {
    test('off-allowlist host is refused before anything loads', () async {
      final result =
          await BrowserDriver.instance.navigateTo('https://youtube.com/');
      expect(result.ok, isFalse);
      expect(result.message, contains('youtube.com'));
      expect(platform.lastController.loadedUrls, isEmpty);
    });

    test('a non-web scheme is refused', () async {
      final result =
          await BrowserDriver.instance.navigateTo('tel:+15551234567');
      expect(result.ok, isFalse);
      expect(platform.lastController.loadedUrls, isEmpty);
    });

    test('no controller fails honestly', () async {
      BrowserDriver.instance.resetForTest();
      final result =
          await BrowserDriver.instance.navigateTo('https://app.artistly.ai/');
      expect(result.ok, isFalse);
      expect(result.message, contains('not ready'));
    });

    test('happy path loads the URL and returns the landed URL and title',
        () async {
      platform.lastController.currentUrlValue = 'https://app.artistly.ai/';
      final result =
          await BrowserDriver.instance.navigateTo('https://app.artistly.ai/');
      expect(result.ok, isTrue);
      expect(result.url, 'https://app.artistly.ai/');
      expect(result.title, 'Fake page');
      expect(
        platform.lastController.loadedUrls,
        [Uri.parse('https://app.artistly.ai/')],
      );
    });

    test('a bare domain gains https://', () async {
      platform.lastController.currentUrlValue = 'https://app.artistly.ai/';
      final result =
          await BrowserDriver.instance.navigateTo('app.artistly.ai');
      expect(result.ok, isTrue);
      expect(
        platform.lastController.loadedUrls,
        [Uri.parse('https://app.artistly.ai')],
      );
    });

    test('a redirect off the allowlist is refused after the load',
        () async {
      platform.lastController.currentUrlValue =
          'https://artistly.ai/pricing';
      final result =
          await BrowserDriver.instance.navigateTo('https://app.artistly.ai/');
      expect(result.ok, isFalse);
      expect(result.message, contains('artistly.ai/pricing'));
    });
  });

  group('BrowserSnapshot formatting (build #125)', () {
    test('format renders the header, groups, and the truncation note',
        () {
      const snapshot = BrowserSnapshot(
        title: 'Fake Store',
        url: 'https://app.artistly.ai/shop',
        elements: [
          BrowserSnapshotElement(
            ref: 1,
            kind: 'heading',
            label: 'Fake Store',
          ),
          BrowserSnapshotElement(
            ref: 2,
            kind: 'input',
            label: 'Email address',
          ),
          BrowserSnapshotElement(
            ref: 3,
            kind: 'password',
            label: 'Password',
          ),
          BrowserSnapshotElement(
            ref: 4,
            kind: 'button',
            label: 'Buy now — \$9.99',
            mutating: true,
          ),
        ],
        dropped: 2,
      );
      final text = snapshot.format();
      expect(
        text,
        contains(
          'Page: Fake Store — https://app.artistly.ai/shop (step 1 of 10)',
        ),
      );
      expect(text, contains('[1] heading "Fake Store"'));
      expect(text, contains('[2] input "Email address"'));
      expect(
        text,
        contains('[3] password "Password" (password — never fill)'),
      );
      expect(
        text,
        contains('[4] button "Buy now — \$9.99" (confirm before using)'),
      );
      expect(
        text,
        contains('+ 2 more elements below — scroll to see them.'),
      );
    });

    test('format caps at 60 elements and counts the rest', () {
      final snapshot = BrowserSnapshot(
        title: 'Long page',
        url: 'https://app.artistly.ai/long',
        elements: [
          for (var i = 1; i <= 65; i++)
            BrowserSnapshotElement(
              ref: i,
              kind: 'link',
              label: 'Filler link $i',
            ),
        ],
        dropped: 5,
      );
      final text = snapshot.format();
      expect(text, contains('[60] link "Filler link 60"'));
      expect(text, isNot(contains('[61]')));
      expect(
        text,
        contains('+ 10 more elements below — scroll to see them.'),
      );
    });

    test('fingerprint changes when the page changes', () {
      const a = BrowserSnapshot(
        title: 'A',
        url: 'https://app.artistly.ai/a',
        elements: [],
        dropped: 0,
      );
      const b = BrowserSnapshot(
        title: 'A',
        url: 'https://app.artistly.ai/a',
        elements: [],
        dropped: 0,
      );
      const c = BrowserSnapshot(
        title: 'A',
        url: 'https://app.artistly.ai/b',
        elements: [],
        dropped: 0,
      );
      expect(a.fingerprint, b.fingerprint);
      expect(a.fingerprint, isNot(c.fingerprint));
    });

    test('mutating labels are detected, plain labels are not', () {
      expect(BrowserDriver.isMutatingLabel('Buy now — \$9.99'), isTrue);
      expect(BrowserDriver.isMutatingLabel('Submit order'), isTrue);
      expect(BrowserDriver.isMutatingLabel('Checkout'), isTrue);
      expect(BrowserDriver.isMutatingLabel('Sign in'), isFalse);
      expect(BrowserDriver.isMutatingLabel('About us'), isFalse);
    });
  });

  group('BrowserDriver.snapshotPage (build #125)', () {
    test('snapshot formats the page with numbered refs and markers',
        () async {
      final snapshot = await BrowserDriver.instance.snapshotPage();
      expect(snapshot, isNotNull);
      final text = snapshot!.format();
      expect(
        text,
        contains(
          'Page: Fake Store — https://app.artistly.ai/shop (step 1 of 10)',
        ),
      );
      expect(text, contains('[1] heading "Fake Store"'));
      expect(text, contains('[2] input "Email address"'));
      expect(
        text,
        contains('[3] password "Password" (password — never fill)'),
      );
      expect(text, contains('[4] button "Sign in"'));
      expect(
        text,
        contains('[5] button "Buy now — \$9.99" (confirm before using)'),
      );
      expect(text, contains('[6] link "About us"'));
      // The snapshot script tags refs on the page for click/fill.
      expect(
        platform.lastController.scripts.join('\n'),
        contains('data-clawzilla-ref'),
      );
    });

    test('snapshot reports elements the page left out', () async {
      agentPage.dropped = 12;
      final snapshot = await BrowserDriver.instance.snapshotPage();
      expect(
        snapshot!.format(),
        contains('+ 12 more elements below — scroll to see them.'),
      );
    });

    test('snapshot with no controller returns null', () async {
      BrowserDriver.instance.resetForTest();
      expect(await BrowserDriver.instance.snapshotPage(), isNull);
    });

    test('step and total steps appear in the header', () async {
      final snapshot = await BrowserDriver.instance
          .snapshotPage(step: 4, totalSteps: 10);
      expect(snapshot!.format(), contains('(step 4 of 10)'));
    });
  });

  group('BrowserDriver.clickRef (build #125)', () {
    test('clicks a button ref and reports it mutating when the label '
        'says so', () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.clickRef(5);
      expect(result.ok, isTrue);
      expect(result.label, 'Buy now — \$9.99');
      expect(result.mutating, isTrue);
      expect(agentPage.clickedRef, 5);
    });

    test('clicking a plain link is not mutating', () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.clickRef(6);
      expect(result.ok, isTrue);
      expect(result.mutating, isFalse);
    });

    test('an unknown ref fails honestly without touching the page',
        () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.clickRef(99);
      expect(result.ok, isFalse);
      expect(result.message, contains('No element [99]'));
      expect(agentPage.clickedRef, isNull);
      expect(
        platform.lastController.scripts.join('\n'),
        isNot(contains("kind: 'click'")),
      );
    });

    test('a heading ref is refused, not clicked', () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.clickRef(1);
      expect(result.ok, isFalse);
      expect(result.message, contains('not something to click'));
      expect(agentPage.clickedRef, isNull);
    });

    test('a disabled element fails honestly', () async {
      agentPage.elements[3].enabled = false; // the Sign in button
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.clickRef(4);
      expect(result.ok, isFalse);
      expect(result.message, contains('disabled'));
      expect(agentPage.clickedRef, isNull);
    });
  });

  group('BrowserDriver.fillRef (build #125)', () {
    test('fills a text field and verifies the value stuck', () async {
      await BrowserDriver.instance.snapshotPage();
      final result =
          await BrowserDriver.instance.fillRef(2, 'aaron@example.com');
      expect(result.ok, isTrue);
      expect(result.value, 'aaron@example.com');
      expect(agentPage.filledValue, 'aaron@example.com');
    });

    test('a password field is refused and nothing is typed', () async {
      await BrowserDriver.instance.snapshotPage();
      final result =
          await BrowserDriver.instance.fillRef(3, 'hunter2');
      expect(result.ok, isFalse);
      expect(result.message, contains('password'));
      expect(agentPage.filledValue, isNull);
      expect(agentPage.elements[2].value, isEmpty);
    });

    test('a password field is refused by the page script too, with no '
        'snapshot', () async {
      // No snapshot taken, so the driver cannot check the kind itself —
      // the page script is the guard.
      final result =
          await BrowserDriver.instance.fillRef(3, 'hunter2');
      expect(result.ok, isFalse);
      expect(result.message, contains('password'));
      expect(agentPage.filledValue, isNull);
    });

    test('an unknown ref fails honestly', () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.fillRef(99, 'x');
      expect(result.ok, isFalse);
      expect(result.message, contains('No element [99]'));
    });

    test('a value that does not stick fails honestly', () async {
      agentPage.fillSticks = false;
      await BrowserDriver.instance.snapshotPage();
      final result =
          await BrowserDriver.instance.fillRef(2, 'aaron@example.com');
      expect(result.ok, isFalse);
      expect(result.message, contains('did not stick'));
    });

    test('empty text is refused', () async {
      await BrowserDriver.instance.snapshotPage();
      final result = await BrowserDriver.instance.fillRef(2, '');
      expect(result.ok, isFalse);
      expect(result.message, contains('empty'));
    });
  });

  group('BrowserDriver.scrollPage (build #125)', () {
    test('scrolls down by one viewport by default', () async {
      final result =
          await BrowserDriver.instance.scrollPage(direction: 'down');
      expect(result.ok, isTrue);
      expect(result.scrollY, 800);
      expect(result.maxScrollY, 1600);
    });

    test('scrolls up and honours an explicit amount', () async {
      await BrowserDriver.instance.scrollPage(direction: 'down');
      final result = await BrowserDriver.instance
          .scrollPage(direction: 'up', amount: 300);
      expect(result.ok, isTrue);
      expect(result.scrollY, 500);
    });

    test('scrolling past the bottom stops at the max', () async {
      final result = await BrowserDriver.instance
          .scrollPage(direction: 'down', amount: 99999);
      expect(result.ok, isTrue);
      expect(result.scrollY, 1600);
    });

    test('an invalid direction fails honestly', () async {
      final result = await BrowserDriver.instance
          .scrollPage(direction: 'sideways');
      expect(result.ok, isFalse);
      expect(result.message, contains('"down" or "up"'));
    });
  });

  group('BrowserDriver.readPageText (build #125)', () {
    test('returns the page text', () async {
      final text = await BrowserDriver.instance.readPageText();
      expect(text, contains('Fake Store'));
      expect(text, contains('Free shipping over \$25.'));
    });

    test('a long page comes back cut with a note', () async {
      final text =
          await BrowserDriver.instance.readPageText(maxChars: 10);
      expect(text, contains('[Text cut off after 10 characters.]'));
      expect(text, startsWith('Fake Store'));
    });

    test('no controller returns null', () async {
      BrowserDriver.instance.resetForTest();
      expect(await BrowserDriver.instance.readPageText(), isNull);
    });
  });
}
