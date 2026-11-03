# pletopay_flutter

Pletopay checkout for Flutter. Your server creates a checkout session with its secret key; the app shows the hosted bank-transfer checkout in a WebView and knows when the customer has paid. No key of any kind ships in the app: the session token is all the checkout API needs.

- `PletopayCheckout`: the hosted page in a WebView (`webview_flutter`). Completion is detected by intercepting the redirect to your `success_url` **and** by polling the session, so it works with or without a `success_url`.
- `PletopayCheckoutClient`: a headless client for the token-authenticated checkout API, for a fully native screen (account details, countdown, status).

## Install

```yaml
dependencies:
  pletopay_flutter: ^1.0.0
```

`webview_flutter` needs iOS 12+ and Android SDK 21+ (see its [setup notes](https://pub.dev/packages/webview_flutter)).

## Checkout in a WebView

```dart
import 'package:pletopay_flutter/pletopay_flutter.dart';

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({required this.token, super.key});
  final String token; // from your server: POST /api/v1/checkout/sessions → data.token

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: PletopayCheckout(
          session: token,
          onSuccess: (result) => Navigator.of(context).pop(result), // confirm server-side before fulfilling
          onCancel: () => Navigator.of(context).pop(),
          onExpired: (_) => Navigator.of(context).pop(),
          onError: (error) => showError(error.message),
          onSessionChange: (s) => s.paymentStatus == PaymentStatus.processing ? showBanner('Transfer received, confirming…') : null,
        ),
      );
}
```

Parameters: `session` (token or hosted URL), `onSuccess`, `onCancel`, `onExpired`, `onError`, `onSessionChange`, `poll` (default true), `pollInterval` (default 4 s, minimum 2 s), `loadingBuilder`, `client`.

The widget never navigates to your `success_url` or `cancel_url`: it intercepts those requests and calls your callbacks instead, so your app decides what to show. `onSuccess` fires once, whichever signal arrives first. Leaving the screen never cancels a transfer the customer already sent; if the money arrives later the session still completes and your server receives `checkout.session.completed`.

## Headless: a native checkout screen

```dart
final client = PletopayCheckoutClient();

final opened = await client.openSession(token); // issues the account details (idempotent)
final transfer = opened.bankTransfer!;
print('Transfer ₦${opened.amount / 100} to ${transfer.accountNumber} (${transfer.accountName}, ${transfer.bankName}) before ${transfer.expiresAt}');

final subscription = client.watchSession(token, initial: opened).listen((session) {
  if (session.paymentStatus == PaymentStatus.processing) showBanner('Transfer received, confirming…');
  if (session.isComplete) showThanks();
  if (session.isExpired) showExpired();
});
// subscription.cancel() when the screen goes away; client.close() when done.
```

`getSession`, `openSession`, `watchSession` (a stream that completes with the final state), `pollSession` (a future of the final state), `hostedUrl` and `resolveToken`. Errors are `PletopayCheckoutException` with `code` (the API's code, e.g. `resource_missing` for an unknown token, `checkout_session_not_open`, `rate_limited`, `service_unavailable`; or the SDK's `network_error`, `timeout`, `invalid_session`), `statusCode` and `retryable`.

Pass `apiUrl` / `checkoutUrl` only to point at a non-production environment; the defaults are the production origins.

## Confirming payment

A success callback is a hint, not proof. Fulfil from your server: handle the `checkout.session.completed` webhook (signature verified) or retrieve the session with your secret key and check `status == "complete"`.

## Development

```bash
flutter pub get
flutter analyze
flutter test
dart format --set-exit-if-changed .
dart pub publish --dry-run
```

## License

[MIT](LICENSE)
