/// The in-app browser — Aaron's own browser inside Clawzilla.
///
/// One page at a time: no extra tabs, no downloads, no saved history, no
/// stored logins. It does not save usernames or passwords — but it does keep
/// a site's own session (cookies/localStorage) like any browser: nothing in
/// the app clears them (build #113 audit: no CookieManager/cache clearing
/// anywhere in lib/ or android/, and the tab stays mounted, so the WebView
/// is created once per app launch). Once Aaron signs in to Artistly or
/// VideoExpress, the chip should land him straight in until the site's own
/// session expires — only a session-only cookie (one the site never gives
/// an expiry) is lost when the app is killed, and that is the site's
/// choice, not the app's. Search goes to Brave Search (Aaron's pick, Nov 7, 2026), never
/// Google. The engine underneath is Android System WebView — Android does not
/// let an app embed Brave's own engine, so only the search default is Brave.
///
/// A link tapped in a chat message opens here instead of leaving the app —
/// the tile writes [browserOpenRequestProvider] and this screen loads it.
///
/// Build #114: Cypher can now drive this browser through one tool,
/// `generate_on_site` — it opens Artistly in here, types the prompt, and
/// hits generate, all inside Aaron's already-signed-in session. The tool
/// goes through [BrowserDriver], which this screen registers its
/// controller with below; the agent still cannot browse freely, click
/// anything else, or touch a login form.
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
import '../../data/services/browser_driver.dart';

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
    // Build #111: tapping the bar selects the whole address (see
    // [_selectAllAddress]) — before this the cursor landed in the middle
    // of the old URL, so what Aaron typed was inserted into it and the
    // load failed silently.
    _addressFocus.addListener(_onAddressFocusChanged);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Build #114: the page can push messages to the driver through the
      // `Clawzilla` channel (the push path for later recipes; v1 polls
      // instead). Registered before the first load, since a channel only
      // takes effect after the next page load.
      ..addJavaScriptChannel(
        'Clawzilla',
        onMessageReceived: (message) {
          BrowserDriver.instance.onChannelMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: (url) async {
            // Build #114: the driver waits on page loads (the
            // `generate_on_site` recipe arms its wait before navigating).
            BrowserDriver.instance.notifyPageFinished(url);
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
          onWebResourceError: (error) {
            // A failed load used to fail silently (build #111): nothing
            // changed on screen, so a bad address looked like a broken
            // bar. Main-frame failures now say so, and the stuck progress
            // bar clears. Sub-frame failures (an ad, a tracker) stay
            // quiet — the page itself still loaded.
            if (error.isForMainFrame != true) return;
            if (!mounted) return;
            setState(() => _progress = 100);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:
                    Text('Could not load this page: ${error.description}'),
              ),
            );
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
    // Build #114: hand the controller to the driver so the
    // `generate_on_site` tool can drive this tab. The tab stays mounted
    // for the whole app run, so the controller effectively lives once
    // per launch.
    BrowserDriver.instance.registerController(_controller);
  }

  @override
  void dispose() {
    BrowserDriver.instance.unregisterController(_controller);
    _addressFocus.removeListener(_onAddressFocusChanged);
    _addressController.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _onAddressFocusChanged() {
    if (_addressFocus.hasFocus) _selectAllAddress();
  }

  /// Select the whole address so typing replaces it instead of landing
  /// inside the old URL. Mobile browsers do this on tap; this screen did
  /// not (build #111), so the cursor landed mid-URL and typed text was
  /// inserted into 'https://search.brave.com/' — a garbage URL that failed
  /// silently. Called on focus and on tap: the tap's own cursor placement
  /// runs after the focus change, so the focus listener alone is not
  /// enough.
  void _selectAllAddress() {
    final text = _addressController.text;
    if (text.isEmpty) return;
    _addressController.selection =
        TextSelection(baseOffset: 0, extentOffset: text.length);
  }

  /// Load what is in the address bar (address or Brave search). One path
  /// for the keyboard Go key and the Go button (build #111): the bar used
  /// to depend on the keyboard action key alone, so if it did not fire,
  /// nothing happened at all.
  void _submitAddress() {
    final value = _addressController.text.trim();
    if (value.isEmpty) return;
    unawaited(_openUrl(toBrowsableUrl(value)));
  }

  /// Build #113: back to the Brave home/search page from anywhere in the
  /// browser. Same load path as the chips — the address bar updates too.
  void _goHome() {
    unawaited(_openUrl(BrowserScreen.braveHome));
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
                  icon: const Icon(Icons.home),
                  tooltip: 'Home',
                  onPressed: _goHome,
                ),
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
                    onTap: _selectAllAddress,
                    onSubmitted: (_) => _submitAddress(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: 'Go',
                  onPressed: _submitAddress,
                ),
              ],
            ),
          ),
          // One-tap shortcuts to Aaron's creative tools (Nov 11, 2026):
          // Artistly for images, VideoExpress for video. They are plain
          // websites. Sign-in is the site's own; the browser keeps the
          // session (build #113), so a chip lands him straight in once
          // he has signed in. Build #114: Cypher can also drive Artistly
          // here through the `generate_on_site` tool — the chips are
          // still just shortcuts, not the tool itself.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                ActionChip(
                  label: const Text('Artistly'),
                  avatar: const Icon(Icons.image_outlined, size: 18),
                  tooltip: 'Open Artistly (images)',
                  onPressed: () =>
                      unawaited(_openUrl('https://app.artistly.ai/login')),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: const Text('VideoExpress'),
                  avatar: const Icon(Icons.movie_outlined, size: 18),
                  tooltip: 'Open VideoExpress (video)',
                  onPressed: () =>
                      unawaited(_openUrl('https://app.videoexpress.ai/login')),
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
