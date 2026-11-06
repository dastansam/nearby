import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../voucher/payment.dart';
import '../wallet.dart';
import 'scan.dart';

/// Payer side: scan the payee's request, confirm, sign a voucher offline and show it as a QR.
Future<void> pay(BuildContext context, Wallet wallet, VoucherStore store) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  final qr = await scanQr(context, 'Scan the payment request');
  if (qr == null || !context.mounted) return;
  final request = PaymentRequest.decode(qr);
  if (request == null) return say('Not a USDC payment request');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Pay ${formatUsdc(request.amount)}?'),
      content: Text('To ${request.receiverId}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Pay')),
      ],
    ),
  );
  if (confirmed != true) return;

  final voucher = await signPayment(wallet.key, request);
  await store.put(voucher, VoucherKind.sent);
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(builder: (_) => VoucherScreen(voucher: voucher)));
}

class VoucherScreen extends StatelessWidget {
  final Map<String, dynamic> voucher;
  const VoucherScreen({super.key, required this.voucher});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Show this to the payee')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(formatUsdc(amountOf(voucher)), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 16),
            QrImageView(data: jsonEncode(voucher), size: 320, backgroundColor: Colors.white),
          ]),
        ),
      );
}
