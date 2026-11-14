import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../theme.dart';
import '../voucher/attestation.dart';
import '../voucher/guards.dart';
import '../voucher/nep413.dart';
import '../voucher/payment.dart';
import 'scan.dart';

/// Why [handoff] is not a new payment of [request] that this payee should accept, or null once
/// it is stored as received. [handoff] is what the payer shows: {"v": voucher, "a": attestation},
/// where the attestation may be left out if it is already here (it travels with the voucher on the mesh).
Future<String?> acceptPayment(VoucherStore store, PaymentRequest request, String handoff) async {
  final Object? voucher, attestation;
  try {
    final j = jsonDecode(handoff) as Map;
    (voucher, attestation) = (j['v'], j['a']);
  } catch (_) {
    return 'malformed';
  }
  await keepAttestation(store, attestation);
  final check = await checkPayment(jsonEncode(voucher), request);
  if (check.voucher == null) return check.reason;
  final v = check.voucher!, payer = signerOf(v);
  final refusal =
      checkGuards(v, attestation: await attestationFor(store, payer), theirs: await store.from(payer), now: DateTime.now());
  if (refusal != null) {
    // The refused half of a double-spend is carried on: together with the other half it is the
    // proof the relayer needs.
    if (refusal == 'double-spend') await store.put(v, VoucherKind.relayed);
    return refusal;
  }
  return await store.put(v, VoucherKind.received) ? null : 'replay';
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
  Outcome? _outcome; // the chain's final answer about the payment, once this phone has a signal
  String? _rejectedFor; // or why the chain turns it down for now
  String? _rejection; // why the last scanned voucher was refused
  bool _scanning = false; // a second tap must not stack a second scanner
  late final StreamSubscription<void> _mesh, _claims, _outcomes, _rejections;

  @override
  void initState() {
    super.initState();
    // The payer's phone usually delivers the voucher over the mesh before anyone scans it. Other
    // people's payments arrive the same way; only one signed for this request is ours to judge.
    _mesh = widget.store.puts.listen((p) async {
      final request = _request;
      if (request == null || p.kind != VoucherKind.relayed || !namesRequest(p.voucher, request)) return;
      _show(await acceptPayment(widget.store, request, jsonEncode({'v': p.voucher})));
    });
    // With a signal, the gateway uploads the payment the moment it is stored, and the chain's answer
    // beats the customer out of the door: the live check that the offline guards stand in for. It may
    // even come before the payment is claimed as ours, while it is only carried: put() tells it then.
    _claims = widget.store.puts.listen(_noteOutcome);
    _outcomes = widget.store.outcomes.listen(_noteOutcome);
    _rejections = widget.store.rejections.listen((r) {
      if (_ours(r.voucher)) setState(() => _rejectedFor = r.reason);
    });
  }

  /// Whether [voucher] pays the request on screen, as this payee's own.
  bool _ours(Map<String, dynamic> voucher) => _request != null && namesRequest(voucher, _request!);

  void _noteOutcome(StoredVoucher s) {
    if (s.kind != VoucherKind.received || !_ours(s.voucher)) return;
    setState(() {
      _outcome = s.outcome;
      if (s.outcome != null) _rejectedFor = null;
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
    _claims.cancel();
    _outcomes.cancel();
    _rejections.cancel();
    _amount.dispose();
    super.dispose();
  }

  void _showRequest() {
    final units = parseUsdc(_amount.text);
    if (units == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount like 2.50')));
      return;
    }
    if (BigInt.parse(units) > paymentCap) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('One offline payment can be at most ${formatUsdc(paymentCap.toString())}')));
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
    final refused = _outcome == Outcome.failed || (_outcome == null && _rejectedFor != null);
    final scheme = theme.colorScheme;
    final small = TextStyle(fontSize: 14, height: 1.35, color: scheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: request == null
            ? [
                const SizedBox(height: 28),
                Text('AMOUNT', textAlign: TextAlign.center, style: labelStyle(context)),
                TextField(
                  controller: _amount,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  cursorColor: scheme.primary,
                  style: TextStyle(
                      fontSize: 64, fontWeight: FontWeight.w700, letterSpacing: -2, color: scheme.onSurface, fontFeatures: figures),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '0.00',
                    hintStyle: TextStyle(color: scheme.outlineVariant),
                  ),
                ),
                Text('USDC',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 32),
                FilledButton(onPressed: _showRequest, child: const Text('Show QR')),
                const SizedBox(height: 14),
                Text('Up to ${formatUsdc(paymentCap.toString())} per offline payment.', textAlign: TextAlign.center, style: small),
              ]
            : [
                const SizedBox(height: 8),
                Text(_paid ? 'RECEIVED' : 'REQUEST', textAlign: TextAlign.center, style: labelStyle(context)),
                const SizedBox(height: 8),
                Amount(formatUsdc(request.amount), size: 52),
                const SizedBox(height: 20),
                if (_paid)
                  Center(
                    child: Container(
                      width: 168,
                      height: 168,
                      decoration: BoxDecoration(
                          color: (refused ? scheme.error : scheme.primary).withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: Icon(refused ? Icons.priority_high_rounded : Icons.check_rounded,
                          size: 96, color: refused ? scheme.error : scheme.primary),
                    ),
                  )
                else
                  Center(
                    child: Panel(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                          key: ValueKey(request.encode()), data: request.encode(), size: 260, backgroundColor: Colors.white),
                    ),
                  ),
                const SizedBox(height: 20),
                if (_paid) ...[
                  Text(
                      switch (_outcome) {
                        Outcome.settled => 'Paid and settled on chain',
                        Outcome.failed => 'Paid, but the chain refused it',
                        null => _rejectedFor == null ? 'Paid, pending settlement' : 'Paid, but the chain turns it down for now',
                      },
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700, color: refused ? scheme.error : scheme.onSurface)),
                  const SizedBox(height: 8),
                  if (_outcome == Outcome.failed)
                    Text('The voucher is signed but intents.near will not pay it: do not hand over the goods.',
                        textAlign: TextAlign.center, style: small)
                  else if (refused)
                    Text('intents.near says: $_rejectedFor. It settles only if that changes, so do not count on it.',
                        textAlign: TextAlign.center, style: small)
                  else if (_outcome == null)
                    Text('Checked on this phone. It settles once a phone that holds it has a signal.',
                        textAlign: TextAlign.center, style: small),
                  // Said out loud: without a relayer key this build cannot tell a funded payer from an empty one.
                  if (relayerKey.isEmpty && _outcome == null)
                    Text('The payer\'s balance was not checked: this build trusts no relayer',
                        textAlign: TextAlign.center, style: small),
                ]
                else if (_rejection != null) ...[
                  Text('Rejected: ${guardRefusals[_rejection] ?? _rejection}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.error)),
                  const SizedBox(height: 8),
                  // Refusing cannot unsign the voucher: it pays this request and may still reach the chain.
                  if (guardRefusals.containsKey(_rejection))
                    Text('The payment is validly signed. If it settles anyway, the money still reaches you.',
                        textAlign: TextAlign.center, style: small),
                ]
                else
                  Text('The payer scans this code, then shows you theirs.', textAlign: TextAlign.center, style: small),
                if (!_paid) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _scanVoucher,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan the voucher'),
                  ),
                ],
              ],
      ),
    );
  }
}
