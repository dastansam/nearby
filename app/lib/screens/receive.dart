import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../voucher/payment.dart';
import 'scan.dart';

/// Payee side: ask for an amount, show the request QR, then scan and check the payer's voucher.
class ReceiveScreen extends StatefulWidget {
  final String accountId;
  final VoucherStore store;
  const ReceiveScreen({super.key, required this.accountId, required this.store});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amount = TextEditingController();
  PaymentRequest? _request;
  bool _paid = false;
  String? _rejection; // why the last scanned voucher was refused
  bool _scanning = false; // a second tap must not stack a second scanner

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _showRequest() {
    final units = parseUsdc(_amount.text);
    if (units == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount like 2.50')));
      return;
    }
    setState(() => _request = PaymentRequest(receiverId: widget.accountId, token: usdcToken, amount: units));
  }

  Future<void> _scanVoucher() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final qr = await scanQr(context, 'Scan the voucher');
      if (qr == null) return;
      final check = await checkPayment(qr, _request!);
      var rejection = check.reason;
      if (check.voucher != null && !await widget.store.add(check.voucher!, sent: false)) rejection = 'replay';
      if (!mounted) return;
      setState(() {
        _paid = rejection == null;
        _rejection = rejection;
      });
    } finally {
      _scanning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: request == null
            ? Column(children: [
                TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount', suffixText: 'USDC'),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _showRequest, child: const Text('Show QR')),
              ])
            : Column(children: [
                Text(formatUsdc(request.amount), style: theme.textTheme.headlineMedium),
                const SizedBox(height: 16),
                if (_paid)
                  Icon(Icons.check_circle, size: 160, color: theme.colorScheme.primary)
                else
                  QrImageView(data: request.encode(), size: 260, backgroundColor: Colors.white),
                const SizedBox(height: 16),
                if (_paid)
                  Text('Paid, pending settlement', style: theme.textTheme.titleLarge)
                else if (_rejection != null)
                  Text('Rejected: $_rejection',
                      style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.error)),
                if (!_paid) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _scanVoucher,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan the voucher'),
                  ),
                ],
              ]),
      ),
    );
  }
}
