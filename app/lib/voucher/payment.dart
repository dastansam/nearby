// Payment requests (payee -> payer QR), signing a voucher for one, and the payee's offline checks.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'nep413.dart';

/// USDC on NEAR, as held inside intents.near. 6 decimals.
const usdcToken = 'nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1';
const _usdcDecimals = 6;
const _voucherLifetime = Duration(hours: 72);

/// "2.5" -> "2500000". Null if not a positive amount with at most 6 decimals.
String? parseUsdc(String input) {
  final m = RegExp(r'^(\d+)(?:\.(\d{1,6}))?$').firstMatch(input.trim());
  if (m == null) return null;
  final units = BigInt.parse(m[1]! + (m[2] ?? '').padRight(_usdcDecimals, '0'));
  return units > BigInt.zero ? units.toString() : null;
}

/// "2500000" -> "2.50 USDC"
String formatUsdc(String units) {
  final s = units.padLeft(_usdcDecimals + 1, '0');
  final whole = s.substring(0, s.length - _usdcDecimals);
  final frac = s.substring(s.length - _usdcDecimals).replaceFirst(RegExp(r'0{1,4}$'), '');
  return '$whole.$frac USDC';
}

/// What the payee asks for. Shown as a QR; the payer signs a voucher that matches it.
class PaymentRequest {
  final String receiverId;
  final String token;
  final String amount; // token base units

  const PaymentRequest({required this.receiverId, required this.token, required this.amount});

  String encode() => jsonEncode({'receiver_id': receiverId, 'token': token, 'amount': amount});

  /// Null if [qr] is not a payment request this app can pay. Only USDC for now: every screen
  /// shows amounts as USDC, so another token would put a misleading number in front of the payer.
  static PaymentRequest? decode(String qr) {
    try {
      final j = jsonDecode(qr) as Map<String, dynamic>;
      final amount = j['amount'] as String;
      if (j['token'] != usdcToken || BigInt.parse(amount) <= BigInt.zero) return null;
      return PaymentRequest(receiverId: j['receiver_id'] as String, token: usdcToken, amount: amount);
    } catch (_) {
      return null;
    }
  }
}

/// Payer side, offline: sign a voucher that pays exactly [request]. [saltHex] was cached while online.
Future<Map<String, dynamic>> signPayment(SimpleKeyPair key, PaymentRequest request, String saltHex) => signVoucher(
    key,
    [Transfer(request.receiverId, {request.token: request.amount})],
    DateTime.now().add(_voucherLifetime),
    makeNonce(saltHex));

/// The payee's offline checks on a scanned voucher. Returns the voucher if it is a valid,
/// unexpired payment of exactly [request]; otherwise the reason it was refused.
///
/// The voucher is the payee's only claim on the money, so anything that would make
/// intents.near pay someone else, pay less, or reject it must be refused here. Whether this
/// voucher was already accepted is the store's call (VoucherStore.add).
Future<({Map<String, dynamic>? voucher, String? reason})> checkPayment(String qr, PaymentRequest request,
    {DateTime? now}) async {
  try {
    final v = jsonDecode(qr) as Map<String, dynamic>;
    final reason = await verifyVoucher(v, now: now);
    if (reason != null) return (voucher: null, reason: reason);
    final intents = jsonDecode(v['payload']['message'])['intents'] as List;
    if (intents.length != 1) return (voucher: null, reason: 'mismatch');
    final t = intents[0] as Map;
    final tokens = t['tokens'] as Map;
    // Exactly one transfer, to us, of exactly this token and amount, and nothing we don't understand.
    final matches = t['intent'] == 'transfer' &&
        t['receiver_id'] == request.receiverId &&
        tokens.length == 1 &&
        tokens[request.token] == request.amount &&
        t.keys.every(const {'intent', 'receiver_id', 'tokens', 'memo'}.contains);
    return matches ? (voucher: v, reason: null) : (voucher: null, reason: 'mismatch');
  } catch (_) {
    return (voucher: null, reason: 'malformed');
  }
}

/// Base units a voucher transfers, for display. Only for vouchers we signed or that passed [checkPayment].
String amountOf(Map<String, dynamic> v) =>
    (jsonDecode(v['payload']['message'])['intents'][0]['tokens'] as Map).values.single;
