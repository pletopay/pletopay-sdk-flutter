import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'models.dart';

/// The API origin.
const String kPletopayApiUrl = 'https://api.pletopay.com';

/// The hosted checkout origin.
const String kPletopayCheckoutUrl = 'https://checkout.pletopay.com';

/// The checkout API allows about two requests a second per device; poll no faster than this.
const Duration kPletopayMinPollInterval = Duration(seconds: 2);

/// A session can stay open for a while after its `expires_at` (a transfer sent
/// just before the deadline is still accepted while it is confirmed) and can
/// still become complete then. From `expires_at` on, polling slows to this interval.
const Duration kPletopayPostExpiryPollInterval = Duration(seconds: 15);

/// How long after the session's `expires_at` polling keeps waiting for a final state by default.
const Duration kPletopayPollDeadlineAfterExpiry = Duration(minutes: 30);

final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
final RegExp _hostedPath = RegExp(r'^/c/([A-Za-z0-9_-]{8,64})$');

/// Reads checkout sessions through the customer-facing API, which needs only the
/// session token (no key of any kind). Use it to build a native checkout screen,
/// or let [PletopayCheckout] use it.
class PletopayCheckoutClient {
  /// Creates a client. [apiUrl] and [checkoutUrl] default to the production
  /// origins; pass an [httpClient] to reuse connections or to mock in tests.
  PletopayCheckoutClient({
    String apiUrl = kPletopayApiUrl,
    String checkoutUrl = kPletopayCheckoutUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  })  : apiUrl = _origin(apiUrl, 'apiUrl'),
        checkoutUrl = _origin(checkoutUrl, 'checkoutUrl'),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// The API origin.
  final String apiUrl;

  /// The hosted checkout origin.
  final String checkoutUrl;

  /// Per-request timeout.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttp;

  static String _origin(String value, String name) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw PletopayCheckoutException('invalid_session', '$name is not a valid absolute URL: $value');
    }
    return uri.origin;
  }

  /// The session token from a token or a hosted URL (`…/c/<token>`).
  String resolveToken(String session) {
    final value = session.trim();
    if (_tokenPattern.hasMatch(value)) return value;
    final uri = Uri.tryParse(value);
    final match = uri == null ? null : _hostedPath.firstMatch(uri.path);
    if (match != null) return match.group(1)!;
    throw const PletopayCheckoutException(
      'invalid_session',
      'session must be a checkout session token or its hosted URL (…/c/<token>)',
    );
  }

  /// The hosted checkout page for a session.
  Uri hostedUrl(String session) => Uri.parse('$checkoutUrl/c/${Uri.encodeComponent(resolveToken(session))}');

  /// The session's current state.
  Future<PublicCheckoutSession> getSession(String session) =>
      _request('GET', '/checkout/v1/sessions/${Uri.encodeComponent(resolveToken(session))}');

  /// Opens the session: issues the bank-transfer account (idempotent). Call it
  /// when your own screen is ready to show the details.
  Future<PublicCheckoutSession> openSession(String session) =>
      _request('POST', '/checkout/v1/sessions/${Uri.encodeComponent(resolveToken(session))}/open');

  /// Emits the session's state every [interval] (never below 2 s) while it is
  /// open, then its final state, and completes. Cancel the subscription to stop.
  /// Pass [initial] to start from a state you already fetched. Retryable errors
  /// (rate limit, outage, network failure) are skipped; others end the stream
  /// with an error.
  ///
  /// The session stays open until Pletopay has settled whether a late transfer
  /// arrived, so the stream keeps going past `expires_at`, every 15 s at most
  /// from then on. It ends with a `timeout` error if the session is still open
  /// after [timeout] (default: 30 minutes after `expires_at`).
  Stream<PublicCheckoutSession> watchSession(
    String session, {
    Duration interval = const Duration(seconds: 4),
    PublicCheckoutSession? initial,
    Duration? timeout,
  }) async* {
    final every = interval < kPletopayMinPollInterval ? kPletopayMinPollInterval : interval;
    var current = initial ?? await getSession(session);
    yield current;
    final started = clock.now();
    final deadline = started.add(
      timeout ?? _max(Duration.zero, current.expiresAt.difference(started)) + kPletopayPollDeadlineAfterExpiry,
    );
    while (current.isOpen) {
      if (clock.now().isAfter(deadline)) {
        throw const PletopayCheckoutException('timeout', 'Gave up waiting for the checkout session to complete',
            retryable: true);
      }
      final expired = !clock.now().isBefore(current.expiresAt);
      await Future<void>.delayed(expired ? _max(every, kPletopayPostExpiryPollInterval) : every);
      try {
        current = await getSession(session);
      } on PletopayCheckoutException catch (error) {
        if (error.retryable) continue;
        rethrow;
      }
      yield current;
    }
  }

  /// Polls until the session is no longer open (complete or expired) and returns that state.
  Future<PublicCheckoutSession> pollSession(
    String session, {
    Duration interval = const Duration(seconds: 4),
    PublicCheckoutSession? initial,
    Duration? timeout,
    void Function(PublicCheckoutSession session)? onUpdate,
  }) async {
    late PublicCheckoutSession last;
    await for (final state in watchSession(session, interval: interval, initial: initial, timeout: timeout)) {
      last = state;
      onUpdate?.call(state);
    }
    return last;
  }

  /// Releases the HTTP client this instance created.
  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<PublicCheckoutSession> _request(String method, String path) async {
    final uri = Uri.parse('$apiUrl$path');
    final request = http.Request(method, uri)
      ..headers['accept'] = 'application/json'
      ..headers['x-pletopay-client'] = 'flutter';
    http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
    } on TimeoutException {
      throw PletopayCheckoutException('timeout', '$method $path timed out', retryable: true);
    } on http.ClientException catch (error) {
      throw PletopayCheckoutException('network_error', '$method $path failed: ${error.message}', retryable: true);
    } on Exception catch (error) {
      // `package:http` does not wrap everything the transport throws (a TLS handshake failure, for
      // one). Whatever it was, the request did not get an answer.
      throw PletopayCheckoutException('network_error', '$method $path failed: $error', retryable: true);
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    final envelope = body is Map<String, dynamic> ? body : null;
    final data = envelope?['data'];
    if (response.statusCode >= 200 && response.statusCode < 300 && data is Map<String, dynamic>) {
      return PublicCheckoutSession.fromJson(data);
    }
    final error = envelope?['error'];
    final code = (error is Map<String, dynamic> ? error['code'] as String? : null) ??
        switch (response.statusCode) {
          404 => 'resource_missing',
          429 => 'rate_limited',
          >= 500 => 'service_unavailable',
          _ => 'invalid_response',
        };
    throw PletopayCheckoutException(
      code,
      envelope?['message'] as String? ?? 'Request failed with HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      retryable: response.statusCode == 429 || response.statusCode >= 500,
    );
  }
}

Duration _max(Duration a, Duration b) => a > b ? a : b;
