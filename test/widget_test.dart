import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pletopay_flutter/pletopay_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_webview_platform.dart';
import 'helpers.dart';

void main() {
  late FakeWebViewPlatform platform;

  setUp(() {
    platform = FakeWebViewPlatform();
    WebViewPlatform.instance = platform;
  });

  Future<void> pumpCheckout(WidgetTester tester, PletopayCheckout checkout) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: checkout)));
    await tester.pump(); // first session fetch
  }

  Future<NavigationDecision> navigate(String url) async =>
      await platform.lastDelegate!.onNavigationRequest!(NavigationRequest(url: url, isMainFrame: true));

  testWidgets('loads the hosted page, confirms the success_url redirect with the API and fires onSuccess once',
      (tester) async {
    // Polling is off and the only state read so far is open, which carries no success_url.
    final mock = QueueClient([envelope(sessionJson()), envelope(sessionJson(status: 'complete'))]);
    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test', checkoutUrl: 'https://checkout.pletopay.com', httpClient: mock.client);
    final successes = <String>[];
    final changes = <String>[];
    final errors = <String>[];
    final external = <String>[];
    var cancels = 0;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onSuccess: (r) => successes.add(r.session),
            onCancel: () => cancels++,
            onError: (e) => errors.add(e.code),
            onSessionChange: (s) => changes.add(s.rawStatus),
            onExternalUrl: (u) => external.add(u.toString())));
    expect(find.byKey(const Key('fake-webview')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(platform.lastController!.loaded.toString(), 'https://checkout.pletopay.com/c/$kToken');
    expect(platform.lastController!.javaScriptMode, JavaScriptMode.unrestricted);

    expect(await navigate('https://checkout.pletopay.com/c/$kToken'), NavigationDecision.navigate);
    // The same request twice while the API is asked: one lookup, and neither is navigated to.
    final redirect = navigate('https://shop.test/thanks/?x=1');
    final repeated = navigate('https://shop.test/thanks/?x=1');
    expect(successes, isEmpty);
    expect(await redirect, NavigationDecision.prevent);
    expect(await repeated, NavigationDecision.prevent);
    expect(mock.calls.length, 2);
    expect(successes, [kToken]);
    expect(changes, ['open', 'complete']);
    // The completed session is known now: later redirects are settled without another request.
    expect(await navigate('https://shop.test/thanks'), NavigationDecision.prevent);
    expect(mock.calls.length, 2);
    expect(successes, [kToken]);
    expect(cancels, 0);
    expect(errors, isEmpty);
    expect(external, isEmpty);

    platform.lastDelegate!.onPageFinished!('https://checkout.pletopay.com/c/$kToken');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('confirms a redirect that arrives while the poll still holds an open session', (tester) async {
    final mock = QueueClient([
      envelope(sessionJson()),
      envelope(sessionJson(status: 'complete', paymentStatus: 'succeeded')), // the redirect's lookup
    ]);
    final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
    final successes = <String>[];
    final errors = <String>[];
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            onSuccess: (r) => successes.add(r.session),
            onError: (e) => errors.add(e.code)));
    await tester.pump(const Duration(seconds: 1)); // the next poll is 3 s away
    expect(mock.calls.length, 1);
    expect(await navigate('https://shop.test/thanks'), NavigationDecision.prevent);
    expect(successes, [kToken]);
    // The poll that was already waiting still runs once; it finds the mock out of replies, and that
    // failure is dropped rather than reported or left unhandled. Nothing is fetched after it.
    await tester.pump(const Duration(minutes: 1));
    expect(mock.calls.length, 3);
    expect(successes, [kToken]);
    expect(errors, isEmpty);
  });

  testWidgets('never reports success for a success_url redirect while the API still says open', (tester) async {
    final mock = QueueClient([envelope(sessionJson()), envelope(sessionJson())]);
    final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
    final external = <String>[];
    final errors = <String>[];
    var successes = 0;
    var cancels = 0;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onSuccess: (_) => successes++,
            onCancel: () => cancels++,
            onError: (e) => errors.add(e.code),
            onExternalUrl: (u) => external.add(u.toString())));
    expect(await navigate('https://shop.test/thanks'), NavigationDecision.prevent);
    expect(mock.calls.length, 2);
    expect(successes, 0);
    expect(cancels, 0);
    expect(errors, isEmpty);
    // Not a completed session's success_url, so it is just another link.
    expect(external, ['https://shop.test/thanks']);
  });

  testWidgets('reports the error and falls back to onExternalUrl when the redirect cannot be confirmed',
      (tester) async {
    final mock = QueueClient([
      envelope(sessionJson()),
      http.ClientException('offline'),
      const HandshakeException('bad certificate'),
    ]);
    final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
    final external = <String>[];
    final errors = <PletopayCheckoutException>[];
    var successes = 0;
    var cancels = 0;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onSuccess: (_) => successes++,
            onCancel: () => cancels++,
            onError: errors.add,
            onExternalUrl: (u) => external.add(u.toString())));
    expect(await navigate('https://shop.test/thanks'), NavigationDecision.prevent); // answered, not left hanging
    expect(errors.map((e) => '${e.code}/${e.retryable}'), ['network_error/true']);
    expect(external, ['https://shop.test/thanks']);
    expect(successes, 0);
    // The cancel_url is known from the open session, so going back still works without the API.
    expect(await navigate('https://shop.test/cart'), NavigationDecision.prevent);
    expect(errors.map((e) => '${e.code}/${e.retryable}'), ['network_error/true', 'network_error/true']);
    expect(cancels, 1);
    expect(external, ['https://shop.test/thanks']);
  });

  testWidgets('keeps the WebView on the checkout origin and hands other links to onExternalUrl (SDK-02)',
      (tester) async {
    final mock = QueueClient([envelope(sessionJson()), envelope(sessionJson()), envelope(sessionJson())]);
    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test', checkoutUrl: 'https://checkout.pletopay.com', httpClient: mock.client);
    final external = <String>[];
    var successes = 0;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onSuccess: (_) => successes++,
            onExternalUrl: (u) => external.add(u.toString())));
    expect(await navigate('https://checkout.pletopay.com/c/$kToken?x=1'), NavigationDecision.navigate);
    expect(await navigate('https://help.shop.test/contact'), NavigationDecision.prevent);
    expect(await navigate('mailto:help@shop.test'), NavigationDecision.prevent);
    expect(await navigate('https://checkout.pletopay.com.evil.test/c/x'), NavigationDecision.prevent);
    expect(await navigate('javascript:alert(1)'), NavigationDecision.prevent);
    expect(await navigate('::not a url::'), NavigationDecision.prevent);
    expect(external,
        ['https://help.shop.test/contact', 'mailto:help@shop.test', 'https://checkout.pletopay.com.evil.test/c/x']);
    expect(mock.calls.length, 3); // one lookup per web link that left the checkout origin, none for the rest
    expect(successes, 0);
  });

  testWidgets('intercepts cancel_url and reports expiry', (tester) async {
    var cancels = 0;
    final external = <String>[];
    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson()), envelope(sessionJson())]).client);
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onCancel: () => cancels++,
            onExternalUrl: (u) => external.add(u.toString())));
    expect(await navigate('https://shop.test/cart'), NavigationDecision.prevent);
    expect(cancels, 1);
    expect(external, isEmpty);

    PublicCheckoutSession? expired;
    final expiredClient = PletopayCheckoutClient(
        apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson(status: 'expired'))]).client);
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('b'), session: kToken, client: expiredClient, onExpired: (s) => expired = s));
    expect(expired?.isExpired, isTrue);
  });

  testWidgets('keeps polling past expires_at and reports expiry when the API settles', (tester) async {
    final expiresAt = clock.now().toUtc().add(const Duration(seconds: 10));
    // Polls at 4, 8 and 12 s, then every 15 s: the 21st answer arrives 282 s in, long after expires_at.
    final mock = QueueClient([
      ...List.generate(21, (_) => envelope(sessionJson(expiresAt: expiresAt))),
      envelope(sessionJson(status: 'expired', expiresAt: expiresAt)),
    ]);
    final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
    final errors = <String>[];
    PublicCheckoutSession? expired;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken, client: client, onExpired: (s) => expired = s, onError: (e) => errors.add(e.code)));
    await tester.pump(const Duration(seconds: 281));
    expect(mock.calls.length, 21);
    expect(expired, isNull);
    await tester.pump(const Duration(seconds: 16));
    expect(mock.calls.length, 22);
    expect(expired?.isExpired, isTrue);
    expect(errors, isEmpty);
    await tester.pump(const Duration(hours: 1));
    expect(mock.calls.length, 22); // settled: nothing more is fetched
  });

  testWidgets('polls through a transport failure package:http does not wrap, and surfaces other errors',
      (tester) async {
    final mock = QueueClient([
      envelope(sessionJson()),
      const HandshakeException('bad certificate'),
      envelope(sessionJson(status: 'complete', paymentStatus: 'succeeded')),
    ]);
    final successes = <String>[];
    final errors = <PletopayCheckoutException>[];
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client),
            pollInterval: const Duration(seconds: 2),
            onSuccess: (r) => successes.add(r.session),
            onError: errors.add));
    await tester.pump(const Duration(seconds: 3));
    expect(successes, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(successes, [kToken]); // the failed poll was retried like any other network failure
    expect(errors, isEmpty);

    // The first read failing the same way is reported, not thrown into the zone.
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('b'),
            session: kToken,
            client: PletopayCheckoutClient(
                apiUrl: 'http://api.test',
                httpClient: QueueClient([const HandshakeException('bad certificate')]).client),
            onError: errors.add));
    expect(errors.map((e) => '${e.code}/${e.retryable}'), ['network_error/true']);

    // Anything else that ends polling reaches onError too (here the mock runs out of replies: a StateError).
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('c'),
            session: kToken,
            client: PletopayCheckoutClient(
                apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson())]).client),
            pollInterval: const Duration(seconds: 2),
            onError: errors.add));
    await tester.pump(const Duration(seconds: 3));
    expect(errors.map((e) => e.code), ['network_error', 'unknown']);
    expect(errors.last.message, contains('no reply queued'));
  });

  testWidgets('detects completion by polling when no redirect happens', (tester) async {
    final mock = QueueClient([
      envelope(sessionJson()),
      envelope(sessionJson(paymentStatus: 'processing')),
      envelope(sessionJson(status: 'complete', paymentStatus: 'succeeded')),
    ]);
    final client = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: mock.client);
    final successes = <String>[];
    final changes = <String>[];
    await pumpCheckout(
      tester,
      PletopayCheckout(
          session: kToken,
          client: client,
          pollInterval: const Duration(seconds: 2),
          onSuccess: (r) => successes.add(r.session),
          onSessionChange: (s) => changes.add('${s.paymentStatus?.name}')),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(successes, [kToken]);
    expect(changes, ['null', 'processing', 'succeeded']);
    expect(await navigate('https://shop.test/thanks'), NavigationDecision.prevent);
    expect(successes, [kToken]); // no second onSuccess
  });

  testWidgets('reports invalid sessions, API errors and page errors', (tester) async {
    final errors = <String>[];
    final invalidClient = PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: QueueClient([]).client);
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('a'), session: 'nope', client: invalidClient, onError: (e) => errors.add(e.code)));
    expect(find.byKey(const Key('pletopay-checkout-invalid')), findsOneWidget);
    expect(errors, ['invalid_session']);

    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test', httpClient: QueueClient([apiError(404, 'resource_missing')]).client);
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('b'), session: kToken, client: client, onError: (e) => errors.add(e.code)));
    expect(errors, ['invalid_session', 'resource_missing']);
    platform.lastDelegate!
        .onWebResourceError!(const WebResourceError(errorCode: -2, description: 'net::ERR', isForMainFrame: true));
    expect(errors.last, 'network_error');
  });

  testWidgets('uses a custom loading builder', (tester) async {
    final client =
        PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson())]).client);
    await pumpCheckout(tester,
        PletopayCheckout(session: kToken, client: client, poll: false, loadingBuilder: (_) => const Text('loading…')));
    expect(find.text('loading…'), findsOneWidget);
    platform.lastDelegate!.onPageFinished!('x');
    await tester.pump();
    expect(find.text('loading…'), findsNothing);
  });
}
