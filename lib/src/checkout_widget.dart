import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'checkout_client.dart';
import 'exceptions.dart';
import 'models.dart';

/// The hosted checkout page in a WebView.
///
/// Completion is detected two ways: the page's redirect to your `success_url` is
/// intercepted (never navigated to) and confirmed with the checkout API, and the
/// session is polled through the checkout API. Whichever happens first fires
/// [onSuccess] once.
///
/// ```dart
/// PletopayCheckout(
///   session: token,
///   onSuccess: (result) => Navigator.of(context).pushReplacementNamed('/thanks', arguments: result.session),
///   onCancel: () => Navigator.of(context).pop(),
/// )
/// ```
class PletopayCheckout extends StatefulWidget {
  /// Creates the checkout view for a session token (or hosted URL).
  const PletopayCheckout({
    required this.session,
    super.key,
    this.onSuccess,
    this.onCancel,
    this.onExpired,
    this.onError,
    this.onSessionChange,
    this.onExternalUrl,
    this.poll = true,
    this.pollInterval = const Duration(seconds: 4),
    this.loadingBuilder,
    this.client,
  });

  /// The session token (or hosted URL) your server created with its secret key.
  final String session;

  /// Pletopay saw the transfer. Confirm server-side before fulfilling, then navigate away.
  final void Function(PletopayCheckoutSuccess result)? onSuccess;

  /// The customer chose to go back (`cancel_url`). Leaving never cancels a transfer already sent.
  final VoidCallback? onCancel;

  /// The session expired before completing.
  final void Function(PublicCheckoutSession session)? onExpired;

  /// The page could not load, or the session could not be read.
  final void Function(PletopayCheckoutException error)? onError;

  /// Every session state read from the checkout API: while polling, and when a redirect is
  /// confirmed (e.g. to show "transfer received, confirming…").
  final void Function(PublicCheckoutSession session)? onSessionChange;

  /// A link the checkout page opens that is not on the checkout origin (the merchant's support URL
  /// or `mailto:` address). The WebView never navigates there itself; open it with `url_launcher`
  /// or show it. Without a handler such links do nothing.
  final void Function(Uri url)? onExternalUrl;

  /// Poll the session API so completion is detected even without a `success_url`. Default true.
  final bool poll;

  /// Polling interval, default 4 s (never below 2 s).
  final Duration pollInterval;

  /// Shown until the page has loaded. Default: a centred progress indicator.
  final WidgetBuilder? loadingBuilder;

  /// A client for a non-production environment; defaults to the production origins.
  final PletopayCheckoutClient? client;

  @override
  State<PletopayCheckout> createState() => _PletopayCheckoutState();
}

class _PletopayCheckoutState extends State<PletopayCheckout> {
  PletopayCheckoutClient? _ownClient;
  PletopayCheckoutClient get _client => widget.client ?? (_ownClient ??= PletopayCheckoutClient());
  WebViewController? _controller;
  StreamSubscription<PublicCheckoutSession>? _watch;

  /// The last session state read from the API, whichever request read it.
  PublicCheckoutSession? _details;
  bool _loaded = false;
  bool _done = false;

  /// Bumped whenever tracking restarts, so a late answer for an earlier session is dropped.
  int _generation = 0;
  final Map<String, Future<NavigationDecision>> _verifying = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(PletopayCheckout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session || oldWidget.client != widget.client) {
      _stopWatching();
      _controller = null;
      _details = null;
      _loaded = false;
      _done = false;
      _generation++;
      _verifying.clear();
      _start();
    }
  }

  @override
  void dispose() {
    _stopWatching();
    _ownClient?.close();
    super.dispose();
  }

  void _start() {
    final Uri url;
    try {
      url = _client.hostedUrl(widget.session);
    } on PletopayCheckoutException catch (error) {
      widget.onError?.call(error);
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageFinished: (_) => _setLoaded(),
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) {
              widget.onError?.call(
                PletopayCheckoutException('network_error', 'The checkout page failed to load: ${error.description}',
                    retryable: true),
              );
            }
          },
        ),
      );
    unawaited(_controller!.loadRequest(url));
    unawaited(_track());
  }

  /// Stops polling. A poll already under way still runs to its end; if it fails, that error
  /// belongs to a session nobody is waiting on any more and is dropped rather than left unhandled.
  void _stopWatching() {
    _watch?.cancel().ignore();
    _watch = null;
  }

  void _setLoaded() {
    if (!mounted || _loaded) return;
    setState(() => _loaded = true);
  }

  Future<void> _track() async {
    final token = _client.resolveToken(widget.session);
    final PublicCheckoutSession first;
    try {
      first = await _client.getSession(token);
    } catch (error) {
      widget.onError?.call(_asCheckoutException(error));
      return;
    }
    if (!mounted) return;
    _details = first;
    widget.onSessionChange?.call(first);
    if (!first.isOpen) {
      _finish(first.isComplete ? _Outcome.success : _Outcome.expired, first);
      return;
    }
    if (!widget.poll) return;
    _watch = _client.watchSession(token, interval: widget.pollInterval, initial: first).skip(1).listen(
      (session) {
        _details = session;
        widget.onSessionChange?.call(session);
        if (session.isComplete) _finish(_Outcome.success, session);
        if (session.isExpired) _finish(_Outcome.expired, session);
      },
      onError: (Object error) => widget.onError?.call(_asCheckoutException(error)),
    );
  }

  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final details = _details;
    if (!(details?.isComplete ?? false) && _leavesCheckout(request.url)) return _verifyOnce(request.url);
    return _route(request.url, details);
  }

  /// One lookup per URL at a time: a request repeated while it is in flight shares its answer.
  Future<NavigationDecision> _verifyOnce(String url) {
    final pending = _verifying[url];
    if (pending != null) return pending;
    late final Future<NavigationDecision> lookup;
    lookup = _verifyRedirect(url).whenComplete(() {
      if (identical(_verifying[url], lookup)) _verifying.remove(url);
    });
    return _verifying[url] = lookup;
  }

  /// An http(s) URL that is not on the checkout origin: a redirect to the merchant, or a link the page opens.
  bool _leavesCheckout(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return false;
    return uri.origin != _client.checkoutUrl;
  }

  /// The page is leaving the checkout origin and no completed session is known here yet (polling is
  /// off, or its last answer predates the completion). Asks the API once whether the session
  /// completed, then treats the URL accordingly. The navigation never happens either way.
  Future<NavigationDecision> _verifyRedirect(String url) async {
    final generation = _generation;
    try {
      final fresh = await _client.getSession(widget.session);
      if (!mounted || generation != _generation) return NavigationDecision.prevent;
      // A poll may have read `complete` while this request was in flight: never step back from it.
      if (!(_details?.isComplete ?? false)) {
        _details = fresh;
        widget.onSessionChange?.call(fresh);
      }
    } catch (error) {
      if (!mounted || generation != _generation) return NavigationDecision.prevent;
      widget.onError?.call(_asCheckoutException(error));
    }
    return _route(url, _details);
  }

  /// Decides a navigation from a session state.
  NavigationDecision _route(String url, PublicCheckoutSession? details) {
    // A URL match alone is never success: the API only reveals `success_url` once the session is complete.
    if (details != null && details.isComplete && _sameUrl(url, details.successUrl)) {
      _finish(_Outcome.success, details);
      return NavigationDecision.prevent;
    }
    if (details != null && _sameUrl(url, details.cancelUrl)) {
      _finish(_Outcome.cancel, details);
      return NavigationDecision.prevent;
    }
    // Only the checkout origin renders inside this view. Anything else the page links to (the
    // merchant's support URL or email, or a page a compromised checkout could redirect to) goes to
    // [PletopayCheckout.onExternalUrl], never into the WebView that carries the merchant's name.
    final uri = Uri.tryParse(url);
    if (uri == null) return NavigationDecision.prevent;
    final web = uri.scheme == 'https' || uri.scheme == 'http';
    if (web && uri.origin == _client.checkoutUrl) return NavigationDecision.navigate;
    if (web || uri.scheme == 'mailto') widget.onExternalUrl?.call(uri);
    return NavigationDecision.prevent;
  }

  void _finish(_Outcome outcome, PublicCheckoutSession session) {
    if (_done) return;
    _done = true;
    _stopWatching();
    switch (outcome) {
      case _Outcome.success:
        widget.onSuccess?.call(PletopayCheckoutSuccess(session: _client.resolveToken(widget.session)));
      case _Outcome.cancel:
        widget.onCancel?.call();
      case _Outcome.expired:
        widget.onExpired?.call(session);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.expand(key: Key('pletopay-checkout-invalid'));
    }
    return Stack(
      key: const Key('pletopay-checkout'),
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: controller),
        if (!_loaded)
          widget.loadingBuilder?.call(context) ??
              const ColoredBox(
                color: Colors.white,
                child: Center(child: CircularProgressIndicator()),
              ),
      ],
    );
  }
}

enum _Outcome { success, cancel, expired }

/// Anything that is not already the SDK's exception reaches `onError` as `unknown` rather than being lost.
PletopayCheckoutException _asCheckoutException(Object error) =>
    error is PletopayCheckoutException ? error : PletopayCheckoutException('unknown', error.toString());

bool _sameUrl(String a, String? b) {
  if (b == null) return false;
  final x = Uri.tryParse(a);
  final y = Uri.tryParse(b);
  if (x == null || y == null) return a == b;
  // `Uri.origin` throws for anything but http(s) (a mailto: link, for instance).
  bool web(Uri u) => u.scheme == 'https' || u.scheme == 'http';
  if (!web(x) || !web(y)) return a == b;
  String trim(String path) => path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  return x.origin == y.origin && trim(x.path) == trim(y.path);
}
