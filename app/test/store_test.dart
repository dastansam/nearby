import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '2500000');
  late VoucherStore store;
  late Map<String, dynamic> voucher;

  setUp(() async {
    store = await VoucherStore.open(inMemoryDatabasePath);
    voucher = await signPayment(await Ed25519().newKeyPair(), request);
  });

  // The chain settles each nonce once. A payee who accepts the same voucher twice has handed
  // over goods twice for one payment, and nothing offline would ever tell them.
  test('a voucher shown a second time is not accepted again', () async {
    expect(await store.add(voucher, sent: false), isTrue);
    expect(await store.add(voucher, sent: false), isFalse);
  });

  test('re-spelling the nonce in base64 does not make it a new payment', () async {
    // Dart decodes both base64 alphabets, so "/" and "_" spell the same nonce bytes. The payee's
    // checks refuse the second spelling; the store must not depend on that.
    final key = await Ed25519().newKeyPair();
    final v = await signVoucher(key, [Transfer('merchant.near', {usdcToken: '2500000'})],
        DateTime.now().add(const Duration(hours: 1)), Uint8List(32)..fillRange(0, 32, 0xff));
    final respelled = {
      ...v,
      'payload': {...v['payload'] as Map<String, dynamic>, 'nonce': (v['payload']['nonce'] as String).replaceAll('/', '_')},
    };
    expect(respelled['payload']['nonce'], isNot(v['payload']['nonce']));

    expect(await store.add(v, sent: false), isTrue);
    expect(await store.add(respelled, sent: false), isFalse);
  });

  test('lists what was stored, with the amount to show', () async {
    await store.add(voucher, sent: true);
    final stored = (await store.all()).firstWhere((s) => s.voucher['signature'] == voucher['signature']);
    expect((stored.sent, stored.amount), (true, '2500000'));
    // The payer re-shows this exact voucher instead of signing a second one for the same purchase.
    expect(stored.voucher, voucher);
  });
}
