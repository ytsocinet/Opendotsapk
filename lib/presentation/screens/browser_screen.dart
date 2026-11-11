/// The in-app browser — Aaron's own browser inside Clawzilla.
///
/// One page at a time: no extra tabs, no downloads, no saved history, no
/// stored logins. It is a fresh browser, not Chrome, so sites ask him to sign
/// in again. Search goes to Brave Search (Aaron's pick, Nov 7, 2026), never
/// Google. The engine underneath is Android System WebView — Android does not
/// let an app embed Brave's own engine, so only the search default is Brave.
///
/// Aaron-only in v1: the agent (Cypher) gets no tool for this browser. A link
/// tapped in a chat message opens here instead of leaving the app — the tile
/// writes [browserOpenRequestProvider] and this screen loads it. The agent
/// page-reader is a future step, explicitly decided Nov 7, 2026, not this
/// batch.
///
/// Browsing is network by definition, the same as the web_search tool the app
/// already has. The browser only loads a page when Aaron opens it or taps a
/// link; nothing fetches in the background, and the model's local-only
/// default does not change.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../providers/providers.dart';

/// Turn address-bar text or a tapped link into a URL the WebView can load.
///
/// - Already has an http(s) scheme: used as-is.
/// - Looks like a domain (has a dot, no spaces): `https://` is added.
/// - Anything else: a Brave Search for the words.
String toBrowsableUrl(String input) {
  final text = input.trim();
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return text;
  }
  if (text.contains('.') && !text.contains(' ')) {
    return 'https://$text';
  }
  return 'https://search.brave.com/search?q=${Uri.encodeQueryComponent(text)}';
}

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  /// Brave Search home — what the tab opens on first.
  static const String braveHome = 'https://search.brave.com/';

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  late final WebViewController _controller;
  final TextEditingController _addressController = TextEditingController();
  final FocusNode _addressFocus = FocusNode();

  int _progress = 0;
  String _pageTitle = 'Browser';
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _addressController.text = BrowserScreen.braveHome;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: (url) async {
            final title = await _controller.getTitle();
            final canBack = await _controller.canGoBack();
            final canForward = await _controller.canGoForward();
            if (!mounted) return;
            setState(() {
              _progress = 100;
              _pageTitle =
                  (title == null || title.isEmpty) ? 'Browser' : title;
              _canGoBack = canBack;
              _canGoForward = canForward;
              // Don't clobber what Aaron is typing.
              if (!_addressFocus.hasFocus) _addressController.text = url;
            });
          },
          onNavigationRequest: (request) {
            // A browser, but a plain one: only web pages. Anything else
            // (tel:, mailto:, intent:) stays out — there is no app to hand
            // it to from inside a WebView.
            final uri = Uri.tryParse(request.url);
            if (uri != null &&
                (uri.scheme == 'http' || uri.scheme == 'https')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(BrowserScreen.braveHome));
  }

  @override
  void dispose() {
    _addressController.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  Future<void> _openUrl(String url) async {
    _addressController.text = url;
    _addressFocus.unfocus();
    await _controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    // A link tapped in chat arrives as a URL request. The tab switch is
    // MainScreen's job (it listens too); this screen loads the page and
    // clears the request so a later tap for the same URL still fires.
    // The listen callback runs after the build, so the async load is safe.
    // All tabs stay mounted, so this fires even while the tab is hidden.
    ref.listen<String?>(browserOpenRequestProvider, (previous, next) {
      if (next == null) return;
      ref.read(browserOpenRequestProvider.notifier).state = null;
      unawaited(_openUrl(next));
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(_pageTitle),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () => unawaited(_controller.reload()),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: _canGoBack
                      ? () => unawaited(_controller.goBack())
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: 'Forward',
                  onPressed: _canGoForward
                      ? () => unawaited(_controller.goForward())
                      : null,
                ),
                Expanded(
                  child: TextField(
                    controller: _addressController,
                    focusNode: _addressFocus,
                    decoration: InputDecoration(
                      hintText: 'Search Brave or type an address',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    textInputAction: TextInputAction.go,
                    keyboardType: TextInputType.url,
                    onSubmitted: (value) {
                      if (value.trim().isEmpty) return;
                      unawaited(_openUrl(toBrowsableUrl(value)));
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_progress < 100)
            LinearProgressIndicator(
              value: _progress / 100,
              backgroundColor: Colors.transparent,
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
