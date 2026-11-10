/// A checkout API or network failure.
///
/// [code] is the API's error code (`resource_missing`, `checkout_session_not_open`,
/// `rate_limited`, `service_unavailable`, …) or one of the SDK's own:
/// `network_error`, `timeout`, `invalid_session`, `invalid_response`, `unknown`.
/// [retryable] says whether the same call can simply be retried.
class PletopayCheckoutException implements Exception {
  /// Creates an exception with a stable [code] and a human-readable [message].
  const PletopayCheckoutException(
    this.code,
    this.message, {
    this.statusCode,
    this.retryable = false,
  });

  /// Stable machine-readable code.
  final String code;

  /// What went wrong, for people.
  final String message;

  /// The HTTP status, when the API answered.
  final int? statusCode;

  /// Whether the same call can simply be retried.
  final bool retryable;

  @override
  String toString() => 'PletopayCheckoutException($code${statusCode != null ? ', HTTP $statusCode' : ''}): $message';
}
