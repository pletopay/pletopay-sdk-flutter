## 1.1.0

- Security: the WebView only navigates within the checkout origin. Links the page opens elsewhere (the merchant's support URL or `mailto:` address, or any redirect off the checkout origin) are handed to the new `PletopayCheckout.onExternalUrl` callback and never loaded inside the view. Open them with `url_launcher` from that callback; without a handler they do nothing.
- Fixed: a `mailto:` navigation no longer throws from the `success_url` / `cancel_url` comparison.

## 1.0.0

- Initial release: `PletopayCheckout` WebView widget with `success_url` / `cancel_url` interception and session polling, `PletopayCheckoutClient` (get, open, watch, poll), typed models and `PletopayCheckoutException`.
