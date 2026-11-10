## Unreleased

- Fixed: `PletopayCheckout` now reports a completed payment when the hosted page redirects to your `success_url`, including with `poll: false`. The checkout API only reveals a session's `success_url` once it is complete, so the redirect was not recognised: `onSuccess` never fired without polling, and the address went to `onExternalUrl` instead. The widget now holds the redirect back, reads the session once and calls `onSuccess` only if the API says `complete`; if that read fails, `onError` is called and the address is handled as an ordinary link.
- Fixed: polling no longer gives up one minute after the session's `expires_at`. A session can stay open for a while after `expires_at` and can still complete, so `watchSession`, `pollSession` and `PletopayCheckout` keep polling (every 15 seconds from `expires_at` on) and report `onExpired`, or a late `onSuccess`, instead of `onError` with `timeout`. The default deadline is now 30 minutes after `expires_at`; an explicit `timeout` still wins. The two values are `kPletopayPostExpiryPollInterval` and `kPletopayPollDeadlineAfterExpiry`.
- Fixed: a transport failure that `package:http` does not wrap (a TLS handshake failure, for instance) is now a retryable `network_error` like any other, so polling carries on through it. Before, it ended polling without calling `onError`, or surfaced as an unhandled error.
- Fixed: `PletopayCheckout` passes every error to `onError`. One that is not a `PletopayCheckoutException` arrives with the code `unknown` instead of being dropped, and a poll that fails after the checkout has already finished no longer surfaces as an unhandled error.

## 1.1.0

- Security: the WebView only navigates within the checkout origin. Links the page opens elsewhere (the merchant's support URL or `mailto:` address, or any redirect off the checkout origin) are handed to the new `PletopayCheckout.onExternalUrl` callback and never loaded inside the view. Open them with `url_launcher` from that callback; without a handler they do nothing.
- Fixed: a `mailto:` navigation no longer throws from the `success_url` / `cancel_url` comparison.

## 1.0.0

- Initial release: `PletopayCheckout` WebView widget with `success_url` / `cancel_url` interception and session polling, `PletopayCheckoutClient` (get, open, watch, poll), typed models and `PletopayCheckoutException`.
