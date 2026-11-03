/// Pletopay checkout for Flutter.
///
/// Your server creates a checkout session with its secret key; the app shows the
/// hosted bank-transfer checkout ([PletopayCheckout]) or builds a native screen
/// with [PletopayCheckoutClient]. No key of any kind ships in the app: the
/// session token is all the checkout API needs.
library;

export 'src/checkout_client.dart';
export 'src/checkout_widget.dart';
export 'src/exceptions.dart';
export 'src/models.dart';
