import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A WebView platform that renders nothing and exposes the navigation delegate's callbacks to tests.
class FakeWebViewPlatform extends WebViewPlatform {
  FakeNavigationDelegate? lastDelegate;
  FakeWebViewController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      lastController = FakeWebViewController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      lastDelegate = FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      FakeWebViewWidget(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(PlatformWebViewCookieManagerCreationParams params) =>
      throw UnimplementedError();
}

class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params, this.platform) : super.implementation();

  final FakeWebViewPlatform platform;
  Uri? loaded;
  JavaScriptMode? javaScriptMode;
  PlatformNavigationDelegate? delegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async => loaded = params.uri;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async => javaScriptMode = mode;

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async => delegate = handler;
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback callback) async => onNavigationRequest = callback;

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async => onPageFinished = callback;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async => onWebResourceError = callback;
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: Key('fake-webview'));
}
