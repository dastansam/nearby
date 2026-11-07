import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../voucher/payment.dart';
import 'scan.dart';

/// Why [voucher] (as JSON) is not a new payment of [request], or null once it is stored as received.
Future<String?> acceptPayment(VoucherStore store, PaymentRequest request, String voucher) async {
  final check = await checkPayment(voucher, request);
  if (check.voucher == null) return check.reason;
  return await store.put(check.voucher!, VoucherKind.received) ? null : 'replay';
}

/// Payee side: ask for an amount, show the request QR, then check the payer's voucher, which
/// arrives over the mesh or is scanned from the payer's screen.
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
  late final StreamSubscription<void> _mesh;

  @override
  void initState() {
    super.initState();
    // The payer's phone usually delivers the voucher over the mesh before anyone scans it. Other
    // people's payments arrive the same way; only one signed for this request is ours to judge.
    _mesh = widget.store.puts.listen((p) async {
      final request = _request;
      if (request == null || p.kind != VoucherKind.relayed || !namesRequest(p.voucher, request)) return;
      _show(await acceptPayment(widget.store, request, jsonEncode(p.voucher)));
    });
  }

  /// Shows the outcome of checking a voucher. Once paid, the screen stays paid: a second
  /// voucher for the request, or the same one scanned after it came by radio, changes nothing.
  void _show(String? rejection) {
    if (!mounted || _paid) return;
    setState(() {
      _paid = rejection == null;
      _rejection = rejection;
    });
    // The payment can arrive by radio while the scanner is open on top of this screen.
    final route = ModalRoute.of(context);
    if (_paid && route != null) Navigator.of(context).popUntil((r) => r == route);
  }

  @override
  void dispose() {
    _mesh.cancel();
    _amount.dispose();
    super.dispose();
  }

  void _showRequest() {
    final units = parseUsdc(_amount.text);
    if (units == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount like 2.50')));
      return;
    }
    setState(() => _request =
        PaymentRequest(receiverId: widget.accountId, token: usdcToken, amount: units, id: newRequestId()));
  }

  Future<void> _scanVoucher() async {
    if (_scanning) return;
    _scanning = true;
    try {
      final qr = await scanQr(context, 'Scan the voucher');
      if (qr == null) return;
      _show(await acceptPayment(widget.store, _request!, qr));
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
                  QrImageView(key: ValueKey(request.encode()), data: request.encode(), size: 260, backgroundColor: Colors.white),
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
