import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pletopay_flutter/pletopay_flutter.dart';

import 'helpers.dart';

void main() {
  group('PletopayCheckoutClient', () {
    test('resolves tokens and hosted URLs', () {
      final client = PletopayCheckoutClient(checkoutUrl: 'https://checkout.pletopay.com/');
      expect(client.resolveToken(kToken), kToken);
      expect(client.resolveToken('https://checkout.pletopay.com/c/$kToken'), kToken);
      expect(client.hostedUrl(kToken).toString(), 'https://checkout.pletopay.com/c/$kToken');
      expect(() => client.resolveToken('nope'), throwsA(isA<PletopayCheckoutException>()));
      expect(() => PletopayCheckoutClient(apiUrl: 'not a url'), throwsA(isA<PletopayCheckoutException>()));
    });

    test('reads and opens sessions through the envelope', () async {
      final mock = QueueClient([envelope(sessionJson()), envelope(sessionJson(bankTransfer: transferJson()))]);
      final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
      final before = await client.getSession(kToken);
      expect(before.status, CheckoutSessionStatus.open);
      expect(before.isOpen, isTrue);
      expect(before.merchant.name, 'Ada Stores');
      expect(before.bankTransfer, isNull);
      final opened = await client.openSession(kToken);
      expect(opened.bankTransfer?.accountNumber, '9821110017');
      expect(opened.bankTransfer?.amount, 150000);
      expect(mock.calls.map((r) => '${r.method} ${r.url.path}'), [
        'GET /checkout/v1/sessions/$kToken',
        'POST /checkout/v1/sessions/$kToken/open',
      ]);
      expect(mock.calls.first.headers['accept'], 'application/json');
    });

    test('maps API errors, network errors and bad bodies', () async {
      final mock = QueueClient([
        apiError(404, 'resource_missing'),
        apiError(429, 'rate_limited'),
        http.ClientException('offline'),
        http.Response('<html>', 502),
        http.Response('{"status":true,"message":"x"}', 200),
      ]);
      final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
      await expectLater(
        client.getSession(kToken),
        throwsA(isA<PletopayCheckoutException>()
            .having((e) => e.code, 'code', 'resource_missing')
            .having((e) => e.statusCode, 'status', 404)
            .having((e) => e.retryable, 'retryable', false)),
      );
      await expectLater(
          client.getSession(kToken),
          throwsA(isA<PletopayCheckoutException>()
              .having((e) => e.code, 'code', 'rate_limited')
              .having((e) => e.retryable, 'retryable', true)));
      await expectLater(
          client.getSession(kToken),
          throwsA(isA<PletopayCheckoutException>()
              .having((e) => e.code, 'code', 'network_error')
              .having((e) => e.retryable, 'retryable', true)));
      await expectLater(
          client.getSession(kToken),
          throwsA(isA<PletopayCheckoutException>()
              .having((e) => e.code, 'code', 'service_unavailable')
              .having((e) => e.statusCode, 'status', 502)));
      await expectLater(client.getSession(kToken),
          throwsA(isA<PletopayCheckoutException>().having((e) => e.code, 'code', 'invalid_response')));
    });

    test('parses every status and keeps unknown values', () {
      final s = PublicCheckoutSession.fromJson(
          sessionJson(status: 'teleported', paymentStatus: 'under_review')..['brand_new'] = 1);
      expect(s.status, CheckoutSessionStatus.unknown);
      expect(s.rawStatus, 'teleported');
      expect(s.paymentStatus, PaymentStatus.underReview);
      expect(s.raw['brand_new'], 1);
      expect(PaymentStatus.parse(null), isNull);
      expect(PaymentStatus.parse('odd'), PaymentStatus.unknown);
    });

    test('watchSession polls until the session is no longer open, skipping retryable errors', () {
      fakeAsync((FakeAsync async) {
        final mock = QueueClient([
          envelope(sessionJson()),
          envelope(sessionJson(paymentStatus: 'processing')),
          apiError(503, 'service_unavailable'),
          envelope(sessionJson(status: 'complete', paymentStatus: 'succeeded')),
        ]);
        final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
        final seen = <String>[];
        PublicCheckoutSession? last;
        client
            .pollSession(kToken,
                interval: const Duration(milliseconds: 500),
                onUpdate: (s) => seen.add('${s.rawStatus}/${s.paymentStatus?.name}'))
            .then((s) => last = s);
        async.elapse(const Duration(seconds: 7));
        expect(last?.isComplete, isTrue);
        expect(seen, ['open/null', 'open/processing', 'complete/succeeded']);
        expect(mock.calls.length, 4); // interval was raised to the 2 s minimum
      });
    });

    test('watchSession starts from a known state, is cancellable and times out', () {
      fakeAsync((FakeAsync async) {
        final known = PublicCheckoutSession.fromJson(sessionJson(status: 'complete'));
        final quiet = QueueClient([]);
        PublicCheckoutSession? result;
        PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: quiet.client)
            .pollSession(kToken, initial: known)
            .then((s) => result = s);
        async.flushMicrotasks();
        expect(result, same(known));
        expect(quiet.calls, isEmpty);

        final mock = QueueClient(List.generate(10, (_) => envelope(sessionJson())));
        final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
        final sub = client.watchSession(kToken, interval: const Duration(seconds: 2)).listen((_) {});
        async.elapse(const Duration(seconds: 3));
        sub.cancel();
        async.elapse(const Duration(seconds: 10));
        // The in-flight fetch at cancellation time may complete; nothing is fetched after that.
        expect(mock.calls.length, lessThanOrEqualTo(3));

        Object? error;
        client
            .pollSession(kToken, interval: const Duration(seconds: 2), timeout: const Duration(seconds: 5))
            .catchError((Object e) {
          error = e;
          return PublicCheckoutSession.fromJson(sessionJson());
        });
        async.elapse(const Duration(seconds: 9));
        expect(error, isA<PletopayCheckoutException>().having((e) => e.code, 'code', 'timeout'));
      });
    });
  });
}
