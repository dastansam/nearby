import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';

void main() {
  const request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '2500000');
  final now = DateTime.utc(2026, 11, 6, 12);
  late SimpleKeyPair payer;

  setUp(() async => payer = await Ed25519().newKeyPair());

  Future<String> voucherQr({
    String receiver = 'merchant.near',
    Map<String, String> tokens = const {usdcToken: '2500000'},
    List<Transfer>? intents,
    DateTime? deadline,
    Uint8List? nonce,
  }) async =>
      jsonEncode(await signVoucher(payer, intents ?? [Transfer(receiver, tokens, memo: 'seq:1 prev:00')],
          deadline ?? now.add(const Duration(hours: 72)), nonce ?? makeNonce('252812b3')));

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
  };

  Future<String?> reasonFor(String qr) async => (await checkPayment(qr, request, '252812b3', now: now)).reason;

  // The payee hands over goods on the strength of these checks alone: there is no network
  // to ask. Each refusal below is a way the voucher would fail to pay this payee in full.
  // (Refusing a voucher shown twice is the store's job: see store_test.dart.)
  group('payee accepts a voucher only if it will pay them', () {
    test('accepts what the payer app signs for the request', () async {
      final check = await checkPayment(jsonEncode(await signPayment(payer, request, '252812b3')), request, '252812b3');
      expect(check.reason, isNull);
      expect(amountOf(check.voucher!), '2500000');
    });

    test('accepts a voucher that also carries a memo', () async {
      // The double-spend guards will put a sequence chain in the memo; it must not break acceptance.
      expect(await reasonFor(await voucherQr()), isNull);
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

    test('refuses a nonce without the salt the payee knows', () async {
      // intents.near rejects a nonce whose salt is not in its registry, so this never settles.
      expect(await reasonFor(await voucherQr(nonce: makeNonce('00000000'))), 'salt');
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

  group('payment request', () {
    String requestQr({String token = usdcToken, String amount = '2500000'}) =>
        jsonEncode({'receiver_id': 'merchant.near', 'token': token, 'amount': amount});

    test('survives the QR round trip', () {
      final decoded = PaymentRequest.decode(request.encode())!;
      expect((decoded.receiverId, decoded.token, decoded.amount), ('merchant.near', usdcToken, '2500000'));
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
