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
    voucher = await signPayment(await Ed25519().newKeyPair(), request, '252812b3');
  });

  // The chain settles each nonce once. A payee who accepts the same voucher twice has handed
  // over goods twice for one payment, and nothing offline would ever tell them.
  test('a voucher shown a second time is not accepted again', () async {
    expect(await store.add(voucher, sent: false), isTrue);
    expect(await store.add(voucher, sent: false), isFalse);
  });

  test('re-spelling the nonce in base64 does not make it a new payment', () async {
    // Dart decodes both base64 alphabets, so "/" and "_" spell the same nonce bytes and the
    // signature stays valid. Keyed by the string, the same voucher would be accepted twice.
    final key = await Ed25519().newKeyPair();
    final v = await signVoucher(key, [Transfer('merchant.near', {usdcToken: '2500000'})],
        DateTime.now().add(const Duration(hours: 1)), Uint8List(32)..fillRange(0, 32, 0xff));
    final respelled = {
      ...v,
      'payload': {...v['payload'] as Map<String, dynamic>, 'nonce': (v['payload']['nonce'] as String).replaceAll('/', '_')},
    };
    expect(respelled['payload']['nonce'], isNot(v['payload']['nonce']));
    expect(await verifyVoucher(respelled), isNull, reason: 'the re-spelled voucher still verifies');

    expect(await store.add(v, sent: false), isTrue);
    expect(await store.add(respelled, sent: false), isFalse);
  });

  test('lists what was stored, with the amount to show', () async {
    await store.add(voucher, sent: true);
    expect(await store.all(), contains((sent: true, amount: '2500000')));
  });
}
