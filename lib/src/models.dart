/// Shapes of the token-authenticated checkout API (`/checkout/v1/sessions/{token}`),
/// as a customer sees them.
library;

/// Where a checkout session is.
enum CheckoutSessionStatus {
  /// Waiting for the transfer.
  open,

  /// Pletopay saw the payment. Confirm server-side before fulfilling.
  complete,

  /// The session expired before completing.
  expired,

  /// A value this SDK version does not know.
  unknown;

  /// Parses the API's `status` string.
  static CheckoutSessionStatus parse(String? value) => switch (value) {
        'open' => CheckoutSessionStatus.open,
        'complete' => CheckoutSessionStatus.complete,
        'expired' => CheckoutSessionStatus.expired,
        _ => CheckoutSessionStatus.unknown,
      };
}

/// Status of the payment behind a session (`payment_status`), null until the customer opens the page.
enum PaymentStatus {
  /// Created, no account yet.
  created,

  /// Account issued, waiting for the transfer.
  pending,

  /// A transfer arrived and is being confirmed.
  processing,

  /// A transfer arrived and is under review.
  underReview,

  /// Confirmed.
  succeeded,

  /// Failed.
  failed,

  /// Expired.
  expired,

  /// Reversed.
  reversed,

  /// Partially refunded.
  partiallyRefunded,

  /// Refunded.
  refunded,

  /// A value this SDK version does not know.
  unknown;

  /// Parses the API's `payment_status` string.
  static PaymentStatus? parse(String? value) => switch (value) {
        null => null,
        'created' => PaymentStatus.created,
        'pending' => PaymentStatus.pending,
        'processing' => PaymentStatus.processing,
        'under_review' => PaymentStatus.underReview,
        'succeeded' => PaymentStatus.succeeded,
        'failed' => PaymentStatus.failed,
        'expired' => PaymentStatus.expired,
        'reversed' => PaymentStatus.reversed,
        'partially_refunded' => PaymentStatus.partiallyRefunded,
        'refunded' => PaymentStatus.refunded,
        _ => PaymentStatus.unknown,
      };
}

/// The merchant, as customers see them on checkout.
class PublicMerchant {
  /// Creates a merchant description.
  const PublicMerchant({required this.name, this.brandColor, this.supportEmail, this.supportUrl});

  /// Builds from the API's JSON.
  factory PublicMerchant.fromJson(Map<String, dynamic> json) => PublicMerchant(
        name: json['name'] as String? ?? '',
        brandColor: json['brand_color'] as String?,
        supportEmail: json['support_email'] as String?,
        supportUrl: json['support_url'] as String?,
      );

  /// Trading name shown to the customer.
  final String name;

  /// Button/accent colour (`#rrggbb`); null = default.
  final String? brandColor;

  /// Support email, if the merchant set one.
  final String? supportEmail;

  /// Support URL, if the merchant set one.
  final String? supportUrl;
}

/// The account the customer transfers to. Issued when the session is opened.
class BankTransferDetails {
  /// Creates the transfer details.
  const BankTransferDetails({
    required this.accountNumber,
    required this.accountName,
    required this.bankName,
    required this.bankCode,
    required this.amount,
    required this.expiresAt,
  });

  /// Builds from the API's JSON.
  factory BankTransferDetails.fromJson(Map<String, dynamic> json) => BankTransferDetails(
        accountNumber: json['account_number'] as String? ?? '',
        accountName: json['account_name'] as String? ?? '',
        bankName: json['bank_name'] as String? ?? '',
        bankCode: json['bank_code'] as String? ?? '',
        amount: (json['amount'] as num?)?.toInt() ?? 0,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// 10-digit account number.
  final String accountNumber;

  /// Account name to show the customer.
  final String accountName;

  /// The bank holding the account (shown to the payer).
  final String bankName;

  /// The bank's code.
  final String bankCode;

  /// Amount to send, in kobo.
  final int amount;

  /// When the account stops accepting transfers.
  final DateTime expiresAt;
}

/// A checkout session as the customer-facing API returns it.
class PublicCheckoutSession {
  /// Creates a session description.
  const PublicCheckoutSession({
    required this.livemode,
    required this.status,
    required this.rawStatus,
    required this.merchant,
    required this.amount,
    required this.currency,
    required this.expiresAt,
    required this.raw,
    this.description,
    this.paymentStatus,
    this.bankTransfer,
    this.successUrl,
    this.cancelUrl,
  });

  /// Builds from the API's JSON (the `data` member of the envelope).
  factory PublicCheckoutSession.fromJson(Map<String, dynamic> json) {
    final merchant = json['merchant'];
    final transfer = json['bank_transfer'];
    return PublicCheckoutSession(
      livemode: json['livemode'] as bool? ?? false,
      status: CheckoutSessionStatus.parse(json['status'] as String?),
      rawStatus: json['status'] as String? ?? '',
      merchant: merchant is Map<String, dynamic> ? PublicMerchant.fromJson(merchant) : const PublicMerchant(name: ''),
      amount: (json['amount'] as num?)?.toInt() ?? 0,
      currency: json['currency'] as String? ?? 'NGN',
      description: json['description'] as String?,
      paymentStatus: PaymentStatus.parse(json['payment_status'] as String?),
      bankTransfer: transfer is Map<String, dynamic> ? BankTransferDetails.fromJson(transfer) : null,
      successUrl: json['success_url'] as String?,
      cancelUrl: json['cancel_url'] as String?,
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      raw: json,
    );
  }

  /// Test or live.
  final bool livemode;

  /// Where the session is.
  final CheckoutSessionStatus status;

  /// The API's `status` string, also for values this SDK does not know.
  final String rawStatus;

  /// The merchant being paid.
  final PublicMerchant merchant;

  /// Amount in kobo.
  final int amount;

  /// `NGN`.
  final String currency;

  /// What the customer is paying for.
  final String? description;

  /// Status of the payment behind the session; null until the customer opens the page.
  final PaymentStatus? paymentStatus;

  /// The account to pay into, once the session was opened.
  final BankTransferDetails? bankTransfer;

  /// Where the hosted page sends the customer on success.
  final String? successUrl;

  /// Where the hosted page offers to go back to.
  final String? cancelUrl;

  /// When the session expires.
  final DateTime expiresAt;

  /// The full JSON, including fields this SDK version does not know.
  final Map<String, dynamic> raw;

  /// Waiting for the transfer.
  bool get isOpen => status == CheckoutSessionStatus.open;

  /// Pletopay saw the payment.
  bool get isComplete => status == CheckoutSessionStatus.complete;

  /// Expired before completing.
  bool get isExpired => status == CheckoutSessionStatus.expired;
}

/// What [PletopayCheckout] reports when Pletopay saw the payment.
class PletopayCheckoutSuccess {
  /// Creates the result.
  const PletopayCheckoutSuccess({required this.session});

  /// The session token. Verify server-side (webhook or retrieve) before fulfilling.
  final String session;
}
