/// Tests for the in-app browser (build #111).
///
/// The address bar did nothing on Aaron's S23 FE (Nov 16, 2026): he typed
/// an address/search, hit Go, and nothing loaded, while the
/// Artistly/VideoExpress chips did load. The probe (fake WebView platform
/// recording every loadRequest) showed the submit path itself works for a
/// clean value — the defect was upstream of it: tapping the bar left the
/// cursor inside the old URL, so typed text was inserted into
/// 'https://search.brave.com/' and the mangled URL failed silently (no
/// error handler). This file pins the fixed behavior: tap selects all, a
/// visible Go button submits, and a failed main-frame load says so.
///
/// Runs against a fake WebView platform — this VM has no Android SDK, so
/// no real WebView runs here. What the tests prove: the Dart submit path,
/// the selection behavior, and the error feedback. What they cannot prove:
/// that a real device keyboard fires onSubmitted (the Go button removes
/// that dependency) or that a real WebView renders the page.
import 'dart:async';

import 'package:clawzilla/presentation/screens/browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class FakePlatformWebViewController extends PlatformWebViewController {
  FakePlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
    this.loadedUrls,
  ) : super.implementation(params);

  final List<Uri> loadedUrls;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUrls.add(params.uri);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
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
  Future<void> goBack() async {}

  @override
  Future<void> goForward() async {}
}

class FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  FakePlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) : super.implementation(params);

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageFinished;
  ProgressCallback? onProgress;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {
    this.onProgress = onProgress;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

class FakePlatformWebViewWidget extends PlatformWebViewWidget {
  FakePlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) : super.implementation(params);

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class FakeWebViewPlatform extends WebViewPlatform {
  FakeWebViewPlatform(this.loadedUrls);

  final List<Uri> loadedUrls;
  late FakePlatformNavigationDelegate lastDelegate;
  late FakePlatformWebViewController lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    lastController = FakePlatformWebViewController(params, loadedUrls);
    return lastController;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    lastDelegate = FakePlatformNavigationDelegate(params);
    return lastDelegate;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return FakePlatformWebViewWidget(params);
  }
}

Future<void> pumpBrowser(
  WidgetTester tester,
  FakeWebViewPlatform platform,
) async {
  WebViewPlatform.instance = platform;
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(home: Scaffold(body: BrowserScreen())),
    ),
  );
  await tester.pump();
}

void main() {
  group('toBrowsableUrl', () {
    test('domain gets https', () {
      expect(toBrowsableUrl('youtube.com'), 'https://youtube.com');
    });
    test('full https URL passes through', () {
      expect(
        toBrowsableUrl('https://example.com/path?q=1'),
        'https://example.com/path?q=1',
      );
    });
    test('http URL passes through', () {
      expect(toBrowsableUrl('http://example.com'), 'http://example.com');
    });
    test('words become a Brave search', () {
      expect(
        toBrowsableUrl('best drill beats'),
        // Uri.encodeQueryComponent encodes a space as '+'.
        'https://search.brave.com/search?q=best+drill+beats',
      );
    });
    test('surrounding space is trimmed', () {
      expect(toBrowsableUrl('  youtube.com  '), 'https://youtube.com');
    });
  });

  group('browser address bar (build #111)', () {
    testWidgets('initial load requests the Brave home page', (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      expect(loaded, [Uri.parse(BrowserScreen.braveHome)]);
    });

    testWidgets('chip tap reaches loadRequest (control: buttons work)',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      await tester.tap(find.text('Artistly'));
      await tester.pump();
      expect(loaded.last, Uri.parse('https://app.artistly.ai/login'));
    });

    testWidgets('VideoExpress chip tap reaches its login page (build #112)',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      await tester.tap(find.text('VideoExpress'));
      await tester.pump();
      expect(loaded.last, Uri.parse('https://app.videoexpress.ai/login'));
    });

    testWidgets('typing a domain and pressing Go reaches loadRequest',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      // The bar starts with the Brave home URL; a user replaces it.
      await tester.enterText(find.byType(TextField), 'youtube.com');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(loaded.last, Uri.parse('https://youtube.com'));
    });

    testWidgets('typing search words and pressing Go searches Brave',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      await tester.enterText(find.byType(TextField), 'best drill beats');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      expect(
        loaded.last,
        Uri.parse('https://search.brave.com/search?q=best+drill+beats'),
      );
    });

    testWidgets('navigation delegate allows the submitted https URL',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      final decision = await platform.lastDelegate.onNavigationRequest!(
        NavigationRequest(url: 'https://youtube.com', isMainFrame: true),
      );
      expect(decision, NavigationDecision.navigate);
    });

    testWidgets('tapping the bar selects the whole address', (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final controller =
          tester.widget<TextField>(find.byType(TextField)).controller!;
      expect(controller.text, 'https://search.brave.com/');
      // Before the fix the cursor landed inside the old URL (offset 17),
      // so typed text was inserted into it. Now the whole address is
      // selected, so typing replaces it.
      expect(controller.selection.baseOffset, 0);
      expect(controller.selection.extentOffset, controller.text.length);
    });

    testWidgets('Go button loads the typed address', (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      await tester.enterText(find.byType(TextField), 'youtube.com');
      await tester.tap(find.byTooltip('Go'));
      await tester.pump();
      expect(loaded.last, Uri.parse('https://youtube.com'));
    });

    testWidgets('a failed main-frame load shows an error, not silence',
        (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      // The progress bar is stuck showing while nothing has finished.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      platform.lastDelegate.onWebResourceError!(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_NAME_NOT_RESOLVED',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Could not load this page'),
        findsOneWidget,
      );
      expect(find.textContaining('ERR_NAME_NOT_RESOLVED'), findsOneWidget);
      // And the stuck progress bar clears.
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a failed sub-frame load stays quiet', (tester) async {
      final loaded = <Uri>[];
      final platform = FakeWebViewPlatform(loaded);
      await pumpBrowser(tester, platform);
      platform.lastDelegate.onWebResourceError!(
        const WebResourceError(
          errorCode: -1,
          description: 'ad failed',
          isForMainFrame: false,
        ),
      );
      await tester.pump();
      expect(find.textContaining('Could not load'), findsNothing);
    });
  });
}
