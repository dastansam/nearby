// Payment requests (payee -> payer QR), signing a voucher for one, and the payee's offline checks.
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';

import 'nep413.dart';

/// USDC on NEAR, as held inside intents.near. 6 decimals.
const usdcToken = 'nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1';
const _usdcDecimals = 6;
const _voucherLifetime = Duration(hours: 72);

/// Memo characters every JSON encoder writes the same way, so the rebuilt message can match.
final _plainAscii = RegExp(r'^[\x20-\x7e]*$');

/// A voucher must still be valid this long after the payee accepts it: it settles only once
/// some phone carries it to the internet, and the payee's clock may be off.
const minTimeToSettle = Duration(hours: 24);

/// "2.5" -> "2500000". Null if not a positive amount with at most 6 decimals.
String? parseUsdc(String input) {
  // Many locales' decimal keypads offer only a comma.
  final m = RegExp(r'^(\d+)(?:\.(\d{1,6}))?$').firstMatch(input.trim().replaceAll(',', '.'));
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

final _requestId = RegExp(r'^[0-9a-f]{16}$');

String newRequestId() => hex.encode(makeNonce().sublist(0, 8));

/// What the payee asks for. Shown as a QR; the payer signs a voucher that matches it.
class PaymentRequest {
  final String receiverId;
  final String token;
  final String amount; // token base units

  /// Random per request ([newRequestId]). The payer signs it into the voucher's memo, so a voucher
  /// that arrives over the mesh can be matched to the request on screen: see [namesRequest].
  final String id;

  const PaymentRequest({required this.receiverId, required this.token, required this.amount, required this.id});

  /// The memo entry that names this request. The memo is a space-separated list, so the
  /// double-spend guards can add their own entries next to it.
  String get memoTag => 'req:$id';

  String encode() => jsonEncode({'receiver_id': receiverId, 'token': token, 'amount': amount, 'id': id});

  /// Null if [qr] is not a payment request this app can pay. Only USDC for now: every screen
  /// shows amounts as USDC, so another token would put a misleading number in front of the payer.
  static PaymentRequest? decode(String qr) {
    try {
      final j = jsonDecode(qr) as Map<String, dynamic>;
      final amount = j['amount'] as String, id = j['id'] as String;
      // Plain positive decimal only: the contract parses it as u128, and BigInt.parse takes "0x10" or "+5".
      if (j['token'] != usdcToken || !RegExp(r'^[1-9]\d*$').hasMatch(amount) || !_requestId.hasMatch(id)) return null;
      return PaymentRequest(receiverId: j['receiver_id'] as String, token: usdcToken, amount: amount, id: id);
    } catch (_) {
      return null;
    }
  }
}

/// Payer side, offline: sign a voucher that pays exactly [request].
Future<Map<String, dynamic>> signPayment(SimpleKeyPair key, PaymentRequest request) => signVoucher(
    key,
    [Transfer(request.receiverId, {request.token: request.amount}, memo: request.memoTag)],
    DateTime.now().add(_voucherLifetime),
    makeNonce());

/// The payee's offline checks on a scanned voucher. Returns the voucher if it is a valid
/// payment of exactly [request] that still has [minTimeToSettle] to run; otherwise the reason
/// it was refused.
///
/// The voucher is the payee's only claim on the money, so anything that would make
/// intents.near pay someone else, pay less, or reject it must be refused here. Whether this
/// voucher was already accepted is the store's call (VoucherStore.put).
Future<({Map<String, dynamic>? voucher, String? reason})> checkPayment(String qr, PaymentRequest request,
    {DateTime? now}) async {
  try {
    final v = jsonDecode(qr) as Map<String, dynamic>;
    final reason = await verifyVoucher(v, now: (now ?? DateTime.now()).add(minTimeToSettle));
    if (reason != null) return (voucher: null, reason: reason);
    // One transfer, to us, of exactly this token and amount, and nothing else: rebuild the
    // message we would sign for this request and require the payer's to be identical. Only the
    // deadline and the memo are the payer's to choose. Which request the memo names is not checked
    // here: a payee who re-enters the amount must still be able to take the voucher already signed.
    final message = v['payload']['message'] as String;
    final msg = jsonDecode(message);
    final memo = msg['intents'][0]['memo'];
    final memoOk = memo == null || (memo is String && _plainAscii.hasMatch(memo));
    final expected = !memoOk
        ? null
        : intentMessage(msg['signer_id'], [Transfer(request.receiverId, {request.token: request.amount}, memo: memo)],
            DateTime.parse(msg['deadline']));
    return message == expected ? (voucher: v, reason: null) : (voucher: null, reason: 'mismatch');
  } catch (_) {
    return (voucher: null, reason: 'malformed');
  }
}

/// Whether [v] was signed for [request] and no other, going by its memo. This is what lets a
/// voucher that arrives by radio mark a request as paid: nobody is holding up a phone, and two
/// customers paying the same amount are otherwise indistinguishable. A voucher naming two
/// requests counts for neither, or one payment could satisfy two tills.
bool namesRequest(Map<String, dynamic> v, PaymentRequest request) {
  try {
    final memo = jsonDecode(v['payload']['message'])['intents'][0]['memo'];
    return memo is String && memo.split(' ').where((e) => e.startsWith('req:')).join(' ') == request.memoTag;
  } catch (_) {
    return false;
  }
}

/// Base units a voucher transfers, for display. Only for vouchers we signed or that passed [checkPayment].
String amountOf(Map<String, dynamic> v) =>
    (jsonDecode(v['payload']['message'])['intents'][0]['tokens'] as Map).values.single;
