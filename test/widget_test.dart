import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  NavigationDecision navigate(String url) =>
      platform.lastDelegate!.onNavigationRequest!(NavigationRequest(url: url, isMainFrame: true)) as NavigationDecision;

  testWidgets('loads the hosted page, intercepts success_url and fires onSuccess once', (tester) async {
    final mock = QueueClient([envelope(sessionJson())]);
    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test', checkoutUrl: 'https://checkout.pletopay.com', httpClient: mock.client);
    final successes = <String>[];
    var cancels = 0;
    await pumpCheckout(
        tester,
        PletopayCheckout(
            session: kToken,
            client: client,
            poll: false,
            onSuccess: (r) => successes.add(r.session),
            onCancel: () => cancels++));
    expect(find.byKey(const Key('fake-webview')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(platform.lastController!.loaded.toString(), 'https://checkout.pletopay.com/c/$kToken');
    expect(platform.lastController!.javaScriptMode, JavaScriptMode.unrestricted);

    expect(navigate('https://checkout.pletopay.com/c/$kToken'), NavigationDecision.navigate);
    expect(navigate('https://shop.test/thanks/?x=1'), NavigationDecision.prevent);
    expect(navigate('https://shop.test/thanks'), NavigationDecision.prevent);
    expect(successes, [kToken]);
    expect(cancels, 0);

    platform.lastDelegate!.onPageFinished!('https://checkout.pletopay.com/c/$kToken');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('keeps the WebView on the checkout origin and hands other links to onExternalUrl (SDK-02)',
      (tester) async {
    final client = PletopayCheckoutClient(
        apiUrl: 'http://api.test',
        checkoutUrl: 'https://checkout.pletopay.com',
        httpClient: QueueClient([envelope(sessionJson())]).client);
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
    expect(navigate('https://checkout.pletopay.com/c/$kToken?x=1'), NavigationDecision.navigate);
    expect(navigate('https://help.shop.test/contact'), NavigationDecision.prevent);
    expect(navigate('mailto:help@shop.test'), NavigationDecision.prevent);
    expect(navigate('https://checkout.pletopay.com.evil.test/c/x'), NavigationDecision.prevent);
    expect(navigate('javascript:alert(1)'), NavigationDecision.prevent);
    expect(navigate('::not a url::'), NavigationDecision.prevent);
    expect(external, ['https://help.shop.test/contact', 'mailto:help@shop.test', 'https://checkout.pletopay.com.evil.test/c/x']);
    expect(successes, 0);
  });

  testWidgets('intercepts cancel_url and reports expiry', (tester) async {
    var cancels = 0;
    final client =
        PletopayCheckoutClient(apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson())]).client);
    await pumpCheckout(
        tester, PletopayCheckout(session: kToken, client: client, poll: false, onCancel: () => cancels++));
    expect(navigate('https://shop.test/cart'), NavigationDecision.prevent);
    expect(cancels, 1);

    PublicCheckoutSession? expired;
    final expiredClient = PletopayCheckoutClient(
        apiUrl: 'http://api.test', httpClient: QueueClient([envelope(sessionJson(status: 'expired'))]).client);
    await pumpCheckout(
        tester,
        PletopayCheckout(
            key: const ValueKey('b'), session: kToken, client: expiredClient, onExpired: (s) => expired = s));
    expect(expired?.isExpired, isTrue);
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
    expect(navigate('https://shop.test/thanks'), NavigationDecision.prevent);
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
