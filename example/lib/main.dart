import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pletopay_flutter/pletopay_flutter.dart';

void main() => runApp(const ShopApp());

/// A tiny shop: your server creates the session, the app shows the checkout.
class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: CartPage());
}

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  bool _busy = false;

  Future<void> _pay() async {
    setState(() => _busy = true);
    try {
      // Your backend calls POST /api/v1/checkout/sessions with its secret key and returns the token.
      final res = await http.post(Uri.parse('https://shop.example.com/api/checkout-session'),
          body: jsonEncode({'orderId': 'ORDER-1'}));
      final token = (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String;
      if (!mounted) return;
      final result = await Navigator.of(context).push<PletopayCheckoutSuccess>(
        MaterialPageRoute(builder: (_) => CheckoutPage(token: token)),
      );
      if (!mounted) return;
      if (result != null) {
        // Pletopay saw the transfer. Your server confirms via the webhook before fulfilling.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paid: session ${result.session}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Cart')),
        body: Center(
          child: FilledButton(onPressed: _busy ? null : _pay, child: const Text('Pay with bank transfer')),
        ),
      );
}

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({required this.token, super.key});

  final String token;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: PletopayCheckout(
          session: token,
          onSuccess: (result) => Navigator.of(context).pop(result),
          onCancel: () => Navigator.of(context).pop(),
          onExpired: (_) => Navigator.of(context).pop(),
          onError: (error) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message))),
        ),
      );
}
