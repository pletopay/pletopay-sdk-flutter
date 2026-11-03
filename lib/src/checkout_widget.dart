import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'checkout_client.dart';
import 'exceptions.dart';
import 'models.dart';

/// The hosted checkout page in a WebView.
///
/// Completion is detected two ways: the page's redirect to your `success_url` is
/// intercepted (never navigated to), and the session is polled through the
/// checkout API. Whichever happens first fires [onSuccess] once.
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

  /// Every session update observed while polling (e.g. to show "transfer received, confirming…").
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
  PublicCheckoutSession? _details;
  bool _loaded = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(PletopayCheckout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session || oldWidget.client != widget.client) {
      unawaited(_watch?.cancel());
      _controller = null;
      _details = null;
      _loaded = false;
      _done = false;
      _start();
    }
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
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

  void _setLoaded() {
    if (!mounted || _loaded) return;
    setState(() => _loaded = true);
  }

  Future<void> _track() async {
    final token = _client.resolveToken(widget.session);
    final PublicCheckoutSession first;
    try {
      first = await _client.getSession(token);
    } on PletopayCheckoutException catch (error) {
      widget.onError?.call(error);
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
      onError: (Object error) {
        if (error is PletopayCheckoutException) widget.onError?.call(error);
      },
    );
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final details = _details;
    if (details != null && _sameUrl(request.url, details.successUrl)) {
      _finish(_Outcome.success, details);
      return NavigationDecision.prevent;
    }
    if (details != null && _sameUrl(request.url, details.cancelUrl)) {
      _finish(_Outcome.cancel, details);
      return NavigationDecision.prevent;
    }
    // Only the checkout origin renders inside this view. Anything else the page links to (the
    // merchant's support URL or email, or a page a compromised checkout could redirect to) goes to
    // [PletopayCheckout.onExternalUrl], never into the WebView that carries the merchant's name.
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final web = uri.scheme == 'https' || uri.scheme == 'http';
    if (web && uri.origin == _client.checkoutUrl) return NavigationDecision.navigate;
    if (web || uri.scheme == 'mailto') widget.onExternalUrl?.call(uri);
    return NavigationDecision.prevent;
  }

  void _finish(_Outcome outcome, PublicCheckoutSession session) {
    if (_done) return;
    _done = true;
    unawaited(_watch?.cancel());
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
