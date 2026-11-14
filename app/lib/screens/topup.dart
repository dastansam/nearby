// Topping up: NEAR sent from any wallet or exchange arrives as USDC in this phone's offline
// balance. NEAR Intents' swap service gives an address to send to and does the rest; the app only
// asks for the address and watches for the money.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import '../theme.dart';
import '../voucher/payment.dart';

const _swapService = 'https://1click.chaindefuser.com/v0';

/// Where to send NEAR, and how much, for [usdc] to arrive.
class TopUpQuote {
  final String depositAddress;
  final BigInt yoctoNear; // what the swap asks for; a little more is returned
  final String usdc; // token base units that will arrive
  const TopUpQuote({required this.depositAddress, required this.yoctoNear, required this.usdc});

  /// The NEAR to send, rounded up to a thousandth so that what a person types is never too little.
  String get near {
    final thousandths = (yoctoNear + BigInt.from(10).pow(21) - BigInt.one) ~/ BigInt.from(10).pow(21);
    return '${thousandths ~/ BigInt.from(1000)}.${(thousandths % BigInt.from(1000)).toString().padLeft(3, '0')}';
  }
}

/// Asks the swap service for an address that turns NEAR into [usdc] base units inside intents.near
/// for [account]. Anything sent beyond what the swap needs comes back to [account] there too.
Future<TopUpQuote> requestTopUp(http.Client client, String account, String usdc, {DateTime? now}) async {
  final response = await client
      .post(Uri.parse('$_swapService/quote'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'dry': false,
            'swapType': 'EXACT_OUTPUT',
            'slippageTolerance': 100,
            'originAsset': 'nep141:wrap.near',
            'depositType': 'ORIGIN_CHAIN',
            'destinationAsset': usdcToken,
            'amount': usdc,
            'recipient': account,
            'recipientType': 'INTENTS',
            'refundTo': account,
            'refundType': 'INTENTS',
            'deadline': (now ?? DateTime.now()).toUtc().add(const Duration(hours: 1)).toIso8601String(),
          }))
      .timeout(const Duration(seconds: 30));
  final Object? body;
  try {
    body = jsonDecode(response.body);
  } catch (_) {
    throw StateError('the swap service answered ${response.statusCode}');
  }
  final quote = body is Map ? body['quote'] : null;
  final address = quote is Map ? quote['depositAddress'] : null;
  final amountIn = quote is Map ? BigInt.tryParse('${quote['amountIn']}') : null;
  // Without both there is nothing safe to show: an address with no amount invites sending too little.
  if (response.statusCode != 200 && response.statusCode != 201 || address is! String || amountIn == null) {
    throw StateError(body is Map && body['message'] != null ? '${body['message']}' : 'the swap service answered ${response.statusCode}');
  }
  return TopUpQuote(depositAddress: address, yoctoNear: amountIn, usdc: usdc);
}

/// How far the money sent to [depositAddress] has got, in the swap service's own word:
/// PENDING_DEPOSIT, PROCESSING, SUCCESS, REFUNDED, FAILED or INCOMPLETE_DEPOSIT.
Future<String> topUpStatus(http.Client client, String depositAddress) async {
  final response = await client
      .get(Uri.parse('$_swapService/status?depositAddress=$depositAddress'))
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) throw StateError('the swap service answered ${response.statusCode}');
  return '${(jsonDecode(response.body) as Map)['status']}';
}

/// Asks how much, shows where to send the NEAR, and waits for it to arrive. Pops with true once it has.
class TopUpScreen extends StatefulWidget {
  final String accountId;
  final http.Client? client;
  const TopUpScreen({super.key, required this.accountId, this.client});

  @override
  State<TopUpScreen> createState() => _TopUpScreenState();
}

class _TopUpScreenState extends State<TopUpScreen> {
  late final http.Client _client = widget.client ?? http.Client();
  final _amount = TextEditingController(text: '1.00');
  TopUpQuote? _quote;
  String _status = 'PENDING_DEPOSIT';
  bool _asking = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    _amount.dispose();
    super.dispose();
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _ask() async {
    final units = parseUsdc(_amount.text);
    if (units == null || BigInt.parse(units) == BigInt.zero) return _say('Enter an amount like 2.50');
    if (_asking) return;
    setState(() => _asking = true);
    try {
      final quote = await requestTopUp(_client, widget.accountId, units);
      if (!mounted) return;
      setState(() => _quote = quote);
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _look());
    } on StateError catch (e) {
      if (mounted) _say('No address for now: ${e.message}');
    } catch (_) {
      if (mounted) _say('No signal: topping up needs the internet');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _look() async {
    final String status;
    try {
      status = await topUpStatus(_client, _quote!.depositAddress);
    } catch (_) {
      return; // asked again in three seconds
    }
    if (!mounted || status == _status) return;
    setState(() => _status = status);
    if (const {'SUCCESS', 'REFUNDED', 'FAILED'}.contains(status)) _poll?.cancel();
  }

  Future<void> _copy(String text, String said) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _say(said);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 14, height: 1.35, color: scheme.onSurfaceVariant);
    final quote = _quote;
    final arrived = _status == 'SUCCESS';
    final lost = _status == 'REFUNDED' || _status == 'FAILED';
    return Scaffold(
      appBar: AppBar(title: const Text('Top up')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: quote == null
            ? [
                const SizedBox(height: 28),
                Text('ADD TO YOUR OFFLINE BALANCE', textAlign: TextAlign.center, style: labelStyle(context)),
                TextField(
                  controller: _amount,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  cursorColor: scheme.primary,
                  style: TextStyle(
                      fontSize: 64, fontWeight: FontWeight.w700, letterSpacing: -2, color: scheme.onSurface, fontFeatures: figures),
                  decoration: const InputDecoration(border: InputBorder.none),
                ),
                Text('USDC',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 32),
                FilledButton(onPressed: _asking ? null : _ask, child: Text(_asking ? 'Asking…' : 'Pay with NEAR')),
                const SizedBox(height: 14),
                Text('You send NEAR from any wallet or exchange. NEAR Intents swaps it and the USDC lands in this phone\'s balance.',
                    textAlign: TextAlign.center, style: small),
              ]
            : [
                const SizedBox(height: 8),
                Text(arrived ? 'ADDED' : 'SEND', textAlign: TextAlign.center, style: labelStyle(context)),
                const SizedBox(height: 8),
                Amount(arrived ? formatUsdc(quote.usdc) : '${quote.near} NEAR', size: 52),
                const SizedBox(height: 20),
                if (arrived || lost)
                  Center(
                    child: Container(
                      width: 168,
                      height: 168,
                      decoration: BoxDecoration(
                          color: (lost ? scheme.error : scheme.primary).withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: Icon(lost ? Icons.priority_high_rounded : Icons.check_rounded,
                          size: 96, color: lost ? scheme.error : scheme.primary),
                    ),
                  )
                else
                  Center(
                    child: Panel(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(data: quote.depositAddress, size: 240, backgroundColor: Colors.white),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                    switch (_status) {
                      'SUCCESS' => 'In your offline balance',
                      'REFUNDED' => 'Not swapped: the NEAR was returned',
                      'FAILED' => 'The swap failed',
                      'PROCESSING' || 'KNOWN_DEPOSIT_TX' => 'NEAR received, swapping to USDC',
                      'INCOMPLETE_DEPOSIT' => 'Too little arrived: send the rest',
                      _ => 'Waiting for your NEAR',
                    },
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700, color: lost ? scheme.error : scheme.onSurface)),
                const SizedBox(height: 8),
                if (arrived)
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))
                else if (lost)
                  Text('What you sent is credited back to this phone\'s account inside NEAR Intents, as NEAR.',
                      textAlign: TextAlign.center, style: small)
                else ...[
                  Text('to this address, on the NEAR network. It becomes ${formatUsdc(quote.usdc)} here in about half a minute. '
                      'A little extra is fine: what the swap does not need is credited back.',
                      textAlign: TextAlign.center, style: small),
                  const SizedBox(height: 16),
                  Panel(
                    onTap: () => _copy(quote.depositAddress, 'Address copied'),
                    child: Row(children: [
                      Expanded(
                        child: Text(quote.depositAddress,
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: scheme.onSurface,
                                fontFamily: 'Menlo',
                                fontFamilyFallback: const ['monospace'])),
                      ),
                      const SizedBox(width: 12),
                      Icon(Icons.copy_outlined, size: 18, color: scheme.onSurfaceVariant),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _copy(quote.near, 'Amount copied'),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: Text('Copy ${quote.near} NEAR'),
                  ),
                ],
              ],
      ),
    );
  }
}
