import 'dart:convert';

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
  }) async =>
      jsonEncode(await signVoucher(payer, intents ?? [Transfer(receiver, tokens, memo: 'seq:1 prev:00')],
          deadline ?? now.add(const Duration(hours: 72)), makeNonce('252812b3')));

  Future<String?> reasonFor(String qr) async => (await checkPayment(qr, request, now: now)).reason;

  // The payee hands over goods on the strength of these checks alone: there is no network
  // to ask. Each refusal below is a way the voucher would fail to pay this payee in full.
  // (Refusing a voucher shown twice is the store's job: see store_test.dart.)
  group('payee accepts a voucher only if it will pay them', () {
    test('accepts what the payer app signs for the request', () async {
      final check = await checkPayment(jsonEncode(await signPayment(payer, request, '252812b3')), request);
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
