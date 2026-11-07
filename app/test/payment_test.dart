import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';

void main() {
  const requestId = '9f2c4e1a7b3d5560';
  const request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '2500000', id: requestId);
  final now = DateTime.utc(2026, 11, 6, 12);
  late SimpleKeyPair payer;

  setUp(() async => payer = await Ed25519().newKeyPair());

  Future<String> voucherQr({
    String receiver = 'merchant.near',
    Map<String, String> tokens = const {usdcToken: '2500000'},
    List<Transfer>? intents,
    DateTime? deadline,
    Uint8List? nonce,
    String? memo = 'req:$requestId seq:1 prev:00',
  }) async =>
      jsonEncode(await signVoucher(payer, intents ?? [Transfer(receiver, tokens, memo: memo)],
          deadline ?? now.add(const Duration(hours: 72)), nonce ?? makeNonce()));

  /// Signs an arbitrary message the way a hostile payer app could, bypassing signVoucher.
  Future<String> handSignedQr(Map<String, dynamic> message, {String? nonceBase64}) async {
    final v = jsonDecode(await voucherQr()) as Map<String, dynamic>;
    final text = jsonEncode({'signer_id': implicitAccount((await payer.extractPublicKey()).bytes), ...message});
    final nonce = nonceBase64 ?? v['payload']['nonce'] as String;
    final sig = await Ed25519().sign(nep413Hash(text, base64.decode(nonce), verifyingContract), keyPair: payer);
    return jsonEncode({
      ...v,
      'payload': {'message': text, 'nonce': nonce, 'recipient': verifyingContract},
      'signature': 'ed25519:${base58.encode(Uint8List.fromList(sig.bytes))}',
    });
  }

  const transfer = {
    'intent': 'transfer',
    'receiver_id': 'merchant.near',
    'tokens': {usdcToken: '2500000'},
    'memo': 'req:$requestId',
  };

  Future<String?> reasonFor(String qr) async => (await checkPayment(qr, request, now: now)).reason;

  // The payee hands over goods on the strength of these checks alone: there is no network
  // to ask. Each refusal below is a way the voucher would fail to pay this payee in full.
  // (Refusing a voucher shown twice is the store's job: see store_test.dart.)
  group('payee accepts a voucher only if it will pay them', () {
    test('accepts what the payer app signs for the request', () async {
      final check = await checkPayment(jsonEncode(await signPayment(payer, request)), request);
      expect(check.reason, isNull);
      expect(amountOf(check.voucher!), '2500000');
    });

    test('accepts a voucher whose memo carries more than the request id', () async {
      // The double-spend guards will put a sequence chain in the memo; it must not break acceptance.
      expect(await reasonFor(await voucherQr()), isNull);
    });

    test('accepts a scanned voucher signed for an earlier request of the same amount', () async {
      // A payee who backed out and typed the amount again shows a new request id. The payer has
      // already signed, and that voucher will settle: refusing it would make them pay twice.
      expect(await reasonFor(await voucherQr(memo: 'req:0000000000000000')), isNull);
      expect(await reasonFor(await voucherQr(memo: null)), isNull);
    });

    test('refuses a voucher that pays someone else', () async {
      expect(await reasonFor(await voucherQr(receiver: 'thief.near')), 'mismatch');
    });

    test('refuses a voucher for a smaller amount', () async {
      expect(await reasonFor(await voucherQr(tokens: {usdcToken: '25'})), 'mismatch');
    });

    test('refuses a voucher in a different token', () async {
      expect(await reasonFor(await voucherQr(tokens: {'nep141:worthless.near': '2500000'})), 'mismatch');
    });

    test('refuses a voucher that bundles a second intent', () async {
      // All intents in one signed message settle or fail together, so an extra transfer
      // the payer cannot fund would sink ours with it.
      final qr = await voucherQr(intents: [
        Transfer('merchant.near', {usdcToken: '2500000'}),
        Transfer('other.near', {usdcToken: '999000000'}),
      ]);
      expect(await reasonFor(qr), 'mismatch');
    });

    test('refuses an expired voucher', () async {
      expect(await reasonFor(await voucherQr(deadline: now.subtract(const Duration(seconds: 1)))), 'expired');
    });

    test('refuses a voucher that would expire before it can reach the chain', () async {
      // Settlement waits for some phone to find a signal. A voucher valid for one more minute
      // passes every signature check and is worthless by the time a gateway submits it.
      expect(await reasonFor(await voucherQr(deadline: now.add(const Duration(minutes: 1)))), 'expired');
      expect(await reasonFor(await voucherQr(deadline: now.add(minTimeToSettle + const Duration(minutes: 1)))), isNull);
    });

    test('refuses a versioned nonce, whose salt and expiry cannot be checked offline', () async {
      // Mainnet rejects "5628f6c6 + version + salt + deadline" nonces with "invalid salt" or
      // "deadline is greater than nonce". A payer could craft one that looks fine and never settles.
      final crafted = Uint8List.fromList([0x56, 0x28, 0xf6, 0xc6, 0, ...List.filled(27, 7)]);
      expect(await reasonFor(await voucherQr(nonce: crafted)), 'nonce');
    });

    // Dart's parsers accept more than the contract's. Each of these is correctly signed and
    // would read fine here, but intents.near could not deserialize it, so it would never pay.
    test('refuses a deadline without a time zone', () async {
      final qr = await handSignedQr({'deadline': '2026-11-12T10:00:00', 'intents': [transfer]});
      expect(await reasonFor(qr), 'deadline');
    });

    test('refuses a nonce in URL-safe base64', () async {
      final nonce = base64Url.encode(Uint8List.fromList([0x25, 0x28, 0x12, 0xb3, ...List.filled(28, 0xff)]));
      expect(nonce, contains('_'));
      final qr = await handSignedQr({'deadline': '2026-11-12T10:00:00.000Z', 'intents': [transfer]}, nonceBase64: nonce);
      expect(await reasonFor(qr), 'malformed');
    });

    test('refuses a correctly signed voucher carrying a field the contract hashes', () async {
      // intents.near includes payload.callback_url in the signed hash; we hash without it. So the
      // signature checks out here and fails on chain.
      final v = jsonDecode(await voucherQr()) as Map<String, dynamic>;
      (v['payload'] as Map<String, dynamic>)['callback_url'] = 'x';
      expect(await reasonFor(jsonEncode(v)), 'malformed');
    });

    test('refuses a key tag that is not a prefix', () async {
      final v = jsonDecode(await voucherQr()) as Map<String, dynamic>;
      v['public_key'] = '${(v['public_key'] as String).substring(8)}ed25519:';
      expect(await reasonFor(jsonEncode(v)), 'malformed');
    });

    test('refuses date spellings only Dart would parse', () async {
      for (final deadline in ['20261112T100000Z', '2026-11-12T10Z', '2026-11-12T10:00:00.000+0000']) {
        expect(await reasonFor(await handSignedQr({'deadline': deadline, 'intents': [transfer]})), 'deadline',
            reason: deadline);
      }
    });

    test('refuses a message with a duplicated key', () async {
      // Dart keeps the last "intents"; the contract's parser rejects the duplicate.
      final good = jsonDecode(await handSignedQr({'deadline': '2026-11-12T10:00:00.000Z', 'intents': [transfer]}));
      final message = (good['payload']['message'] as String).replaceFirst('"intents":', '"intents":[],"intents":');
      final sig = await Ed25519().sign(
          nep413Hash(message, base64.decode(good['payload']['nonce']), verifyingContract),
          keyPair: payer);
      good['payload']['message'] = message;
      good['signature'] = 'ed25519:${base58.encode(Uint8List.fromList(sig.bytes))}';
      expect(await reasonFor(jsonEncode(good)), 'mismatch');
    });

    test('refuses a memo that is not text', () async {
      final qr = await handSignedQr({
        'deadline': '2026-11-12T10:00:00.000Z',
        'intents': [
          {...transfer, 'memo': 17}
        ],
      });
      expect(await reasonFor(qr), 'mismatch');
    });

    test('accepts a hand-signed voucher that is well formed', () async {
      // Guards the three refusals above against passing for the wrong reason.
      expect(await reasonFor(await handSignedQr({'deadline': '2026-11-12T10:00:00.000Z', 'intents': [transfer]})), isNull);
    });

    test('refuses a voucher altered after signing', () async {
      final qr = (await voucherQr(tokens: {usdcToken: '25'})).replaceFirst(r'\"25\"', r'\"2500000\"');
      expect(await reasonFor(qr), 'signature');
    });

    test('refuses a QR that is not a voucher', () async {
      expect(await reasonFor('https://example.com'), 'malformed');
      expect(await reasonFor(request.encode()), 'standard');
    });
  });

  // Vouchers also arrive by radio, with nobody holding up a phone. Two customers paying 2.50
  // are then indistinguishable, and "Paid" would appear for whoever happens to be at the counter.
  group('a voucher arriving by radio counts for a request only if signed for it', () {
    Future<bool> names(String? memo) async => namesRequest(jsonDecode(await voucherQr(memo: memo)), request);

    test('counts when the payer app signed it for this request', () async {
      expect(namesRequest(await signPayment(payer, request), request), isTrue);
      expect(await names('${request.memoTag} seq:1 prev:00'), isTrue);
    });

    test('does not count for another request of the same amount, or for none', () async {
      expect(await names('req:0000000000000000'), isFalse);
      expect(await names(null), isFalse);
    });

    test('does not count when the memo only looks like it names the request', () async {
      expect(await names('x${request.memoTag}'), isFalse);
      expect(await names('${request.memoTag}1'), isFalse);
    });

    test('does not count when it names two requests', () async {
      // Two tills on one merchant account would both show "Paid" for a single payment.
      expect(await names('${request.memoTag} req:0000000000000000'), isFalse);
    });
  });

  group('payment request', () {
    String requestQr({String token = usdcToken, String amount = '2500000', String? id = requestId}) =>
        jsonEncode({'receiver_id': 'merchant.near', 'token': token, 'amount': amount, if (id != null) 'id': id});

    test('survives the QR round trip', () {
      final decoded = PaymentRequest.decode(request.encode())!;
      expect((decoded.receiverId, decoded.token, decoded.amount, decoded.id),
          ('merchant.near', usdcToken, '2500000', requestId));
    });

    test('two requests for the same amount are different requests', () {
      expect(newRequestId(), isNot(newRequestId()));
    });

    test('is refused without an id the memo can carry unchanged', () {
      // The id is signed into the memo as "req:<id>" among space-separated entries, so an id with
      // a space or other text in it could never be matched again.
      for (final bad in [null, '', '9f2c 4e1a7b3d556', '9F2C4E1A7B3D5560', 'x']) {
        expect(PaymentRequest.decode(requestQr(id: bad)), isNull, reason: '$bad');
      }
    });

    test('is not confused with other QR codes or non-positive amounts', () {
      expect(PaymentRequest.decode('hello'), isNull);
      expect(PaymentRequest.decode(requestQr(amount: '0')), isNull);
      expect(PaymentRequest.decode(requestQr(amount: '-5')), isNull);
    });

    test('is refused when the amount is not a plain decimal the contract can parse', () {
      // BigInt.parse would take these, and the payer would sign a voucher that cannot settle.
      for (final bad in ['0x2625a0', '+5', ' 5', '05', '2.5']) {
        expect(PaymentRequest.decode(requestQr(amount: bad)), isNull, reason: bad);
      }
    });

    test('is refused for a token the app cannot show honestly', () {
      // The confirm dialog would read "Pay 2.50 USDC?" for 2500000 units of anything.
      expect(PaymentRequest.decode(requestQr(token: 'nep141:wrap.near')), isNull);
    });
  });

  group('USDC amounts', () {
    // A slip here signs the wrong amount of money, so conversions are exact (no doubles).
    test('typed amounts become exact base units', () {
      expect(parseUsdc('2.5'), '2500000');
      expect(parseUsdc('0.000001'), '1');
      expect(parseUsdc('25'), '25000000');
      expect(parseUsdc('2,5'), '2500000', reason: 'comma-decimal keypads');
    });

    test('rejects amounts that are not payable', () {
      for (final bad in ['', '0', '0.00', '-1', '1.0000001', '1e3', 'abc', '.5']) {
        expect(parseUsdc(bad), isNull, reason: bad);
      }
    });

    test('base units are shown with cents', () {
      expect(formatUsdc('2500000'), '2.50 USDC');
      expect(formatUsdc('1'), '0.000001 USDC');
      expect(formatUsdc('25000000'), '25.00 USDC');
      expect(formatUsdc('1234567'), '1.234567 USDC');
    });
  });
}
