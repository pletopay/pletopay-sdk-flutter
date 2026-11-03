import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String kToken = '0OrCJ44hSQU_xb9de8Z7YiVAN01RQViC';

Map<String, dynamic> sessionJson({
  String status = 'open',
  String? paymentStatus,
  Map<String, dynamic>? bankTransfer,
  String? successUrl = 'https://shop.test/thanks',
  String? cancelUrl = 'https://shop.test/cart',
  DateTime? expiresAt,
}) =>
    {
      'object': 'checkout_session',
      'livemode': false,
      'status': status,
      'merchant': {'name': 'Ada Stores', 'brand_color': null, 'support_email': null, 'support_url': null},
      'amount': 150000,
      'currency': 'NGN',
      'description': null,
      'payment_status': paymentStatus,
      'bank_transfer': bankTransfer,
      'success_url': successUrl,
      'cancel_url': cancelUrl,
      'expires_at': (expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1))).toIso8601String(),
    };

Map<String, dynamic> transferJson() => {
      'account_number': '9821110017',
      'account_name': 'Ada Stores',
      'bank_name': 'Example Bank',
      'bank_code': '090',
      'amount': 150000,
      'expires_at': DateTime.now().toUtc().add(const Duration(minutes: 30)).toIso8601String(),
    };

http.Response envelope(Object data, {int status = 200}) => http.Response(
      jsonEncode({'status': status < 400, 'message': 'ok', 'data': data}),
      status,
      headers: {'content-type': 'application/json'},
    );

http.Response apiError(int status, String code, {String? message}) => http.Response(
      jsonEncode({
        'status': false,
        'message': message ?? '$code happened',
        'error': {'type': 'x', 'code': code},
        'request_id': 'req_1',
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

/// A mock HTTP client answering from a queue and recording every request.
class QueueClient {
  QueueClient(List<Object> replies) : _queue = List.of(replies);

  final List<Object> _queue;
  final List<http.Request> calls = [];

  late final MockClient client = MockClient((request) async {
    calls.add(request);
    if (_queue.isEmpty) throw StateError('no reply queued for ${request.method} ${request.url}');
    final next = _queue.removeAt(0);
    if (next is http.Response) return next;
    if (next is Exception) throw next;
    if (next is http.Response Function(http.Request)) return next(request);
    throw StateError('bad reply $next');
  });
}
