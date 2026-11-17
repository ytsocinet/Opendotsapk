/// Tests for the browser driver (build #114).
///
/// The driver is the bridge between the `generate_on_site` tool and the
/// in-app browser's WebView. There is no Android SDK on this VM, so the
/// tests run against a scripted fake WebView platform: the fake records
/// every load and JS evaluation, and a per-test page model answers the
/// recipe's JS probes the way the real Artistly page would — logged in
/// or logged out, designer shown or not, results appearing or never
/// appearing.
///
/// What the tests prove: the recipe's flow (navigate → login check →
/// designer → fill → generate → poll), the allowlist, honest failures
/// (missing element, login wall, timeout), and that a generation still
/// running at the poll cap reports "still generating" instead of hanging.
/// What they cannot prove: that Artistly's real DOM matches the
/// text-based selectors the recipe uses — every selector in the driver
/// is UNVERIFIED against the live page, and the on-phone test settles
/// that.
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

void main() {
  late ScriptedWebViewPlatform platform;
  late ScriptedArtistlyPage page;

  setUp(() {
    BrowserDriver.instance.resetForTest();
    platform = ScriptedWebViewPlatform();
    WebViewPlatform.instance = platform;
    page = ScriptedArtistlyPage();
    final controller = WebViewController();
    platform.lastController.jsHandler = page.answer;
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
}
