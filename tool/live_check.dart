// Drives the headless client against a running API: dart run tool/live_check.dart <token> [apiUrl] [checkoutUrl]
// (imports only the non-Flutter parts of the package, so plain `dart run` works).
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:pletopay_flutter/src/checkout_client.dart';
import 'package:pletopay_flutter/src/exceptions.dart';

Future<void> main(List<String> args) async {
  final token = args[0];
  final client = PletopayCheckoutClient(
    apiUrl: args.length > 1 ? args[1] : 'http://localhost:8080',
    checkoutUrl: args.length > 2 ? args[2] : 'http://localhost:3007',
  );
  print(
      'hostedUrl ${client.hostedUrl(token)} | token from url ok: ${client.resolveToken(client.hostedUrl(token).toString()) == token}');
  final before = await client.getSession(token);
  print('getSession ${before.rawStatus} bank_transfer=${before.bankTransfer} merchant=${before.merchant.name}');
  final opened = await client.openSession(token);
  print(
      'openSession ${opened.rawStatus} account=${opened.bankTransfer?.accountNumber} amount=${opened.bankTransfer?.amount}');
  stdout.writeln('ACCOUNT ${opened.bankTransfer?.accountNumber} ${opened.amount}');
  final updates = <String>[];
  final last = await client.pollSession(token,
      interval: const Duration(seconds: 2),
      initial: opened,
      onUpdate: (s) => updates.add('${s.rawStatus}/${s.paymentStatus?.name}'));
  print('pollSession -> ${last.rawStatus} ${last.paymentStatus?.name} updates=${updates.join(',')}');
  try {
    await client.getSession('nope-nope-nope');
  } on PletopayCheckoutException catch (e) {
    print('error ${e.code} ${e.statusCode} retryable=${e.retryable}');
  }
  client.close();
}
