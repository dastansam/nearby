import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../theme.dart';
import '../voucher/attestation.dart';
import '../voucher/guards.dart';
import '../voucher/nep413.dart';
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

  final mine = await store.from(wallet.accountId);
  final next = nextSequence(mine);
  final voucher = await signPayment(wallet.key, request, seq: next.seq, prev: next.prev);
  // The payee will run this same check, so a voucher that fails it here is never shown. It is
  // not stored either, which leaves its sequence number free for the next payment.
  final refusal = checkGuards(voucher,
      attestation: await attestationFor(store, wallet.accountId), theirs: mine, now: DateTime.now());
  if (refusal != null) return say(_whyNot[refusal] ?? 'Cannot pay: ${guardRefusals[refusal]}');
  await store.put(voucher, VoucherKind.sent);
  if (!context.mounted) return;
  await showVoucher(context, store, voucher);
}

/// What to tell the payer when their own phone can already see the payee would refuse.
const _whyNot = {
  'attestation': 'Go online once so the app can load your offline balance',
  'stale': 'Go online once so the app can load your offline balance',
  'bond': 'Lock a bond of at least $minimumBondNear NEAR first (see the README), then go online once',
  'balance': 'Not enough offline balance',
};

/// Shows [voucher] as a QR for the payee, together with the payer's balance attestation, which
/// the payee needs and may not have.
Future<void> showVoucher(BuildContext context, VoucherStore store, Map<String, dynamic> voucher) async {
  final attestation = await store.attestation(signerOf(voucher));
  if (!context.mounted) return;
  final handoff = jsonEncode({'v': voucher, if (attestation != null) 'a': attestation});
  await Navigator.push(context, MaterialPageRoute(builder: (_) => VoucherScreen(voucher: voucher, handoff: handoff)));
}

class VoucherScreen extends StatelessWidget {
  final Map<String, dynamic> voucher;
  final String handoff;
  const VoucherScreen({super.key, required this.voucher, required this.handoff});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // As large as the screen allows: the code carries the voucher and the attestation, and is dense.
    final side = (MediaQuery.sizeOf(context).width - 44).clamp(200.0, 340.0);
    return Scaffold(
      appBar: AppBar(title: const Text('Show this to the payee')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('YOU PAY', style: labelStyle(context)),
            const SizedBox(height: 8),
            Amount(formatUsdc(amountOf(voucher)), size: 52),
            const SizedBox(height: 20),
            Panel(
              color: Colors.white,
              padding: const EdgeInsets.all(10),
              child: QrImageView(data: handoff, size: side, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 18),
            Text('Signed on this phone. It settles when a phone that holds it has a signal.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
