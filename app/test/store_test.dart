import 'dart:convert';
import 'dart:io';
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

  const request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '2500000', id: '9f2c4e1a7b3d5560');
  late VoucherStore store;
  late SimpleKeyPair payer;
  late Map<String, dynamic> voucher;

  setUp(() async {
    store = await VoucherStore.open(inMemoryDatabasePath);
    payer = await Ed25519().newKeyPair();
    voucher = await signPayment(payer, request);
  });

  Future<Map<String, dynamic>> sign(String receiver, Uint8List nonce) => signVoucher(
      payer, [Transfer(receiver, {usdcToken: '2500000'})], DateTime.now().add(const Duration(hours: 72)), nonce);

  // The chain settles each signer's nonce once. A payee who accepts the same voucher twice has
  // handed over goods twice for one payment, and nothing offline would ever tell them.
  test('a voucher shown a second time is not accepted again', () async {
    expect(await store.put(voucher, VoucherKind.received), isTrue);
    expect(await store.put(voucher, VoucherKind.received), isFalse);
  });

  test('re-spelling the nonce in base64 does not make it a new payment', () async {
    // Dart decodes both base64 alphabets, so "/" and "_" spell the same nonce bytes. The payee's
    // checks refuse the second spelling; the store must not depend on that.
    final v = await sign('merchant.near', Uint8List(32)..fillRange(0, 32, 0xff));
    final respelled = {
      ...v,
      'payload': {...v['payload'] as Map<String, dynamic>, 'nonce': (v['payload']['nonce'] as String).replaceAll('/', '_')},
    };
    expect(respelled['payload']['nonce'], isNot(v['payload']['nonce']));

    expect(await store.put(v, VoucherKind.received), isTrue);
    expect(await store.put(respelled, VoucherKind.received), isFalse);
  });

  // With the mesh on, the payer's phone often hands the voucher to the payee's phone as a
  // relayed one before the payee scans the QR. That must not turn a real payment into a "replay".
  test('a payee can accept a voucher that reached them over the mesh first', () async {
    expect(await store.put(voucher, VoucherKind.relayed, hops: 1), isTrue);
    expect(await store.put(voucher, VoucherKind.received), isTrue);
    expect((await store.all()).singleWhere((s) => voucherKey(s.voucher) == voucherKey(voucher)).kind,
        VoucherKind.received);
    expect(await store.put(voucher, VoucherKind.received), isFalse, reason: 'and only once');
  });

  test('a payee refuses a voucher when a different one with the same nonce is already around', () async {
    // The payer signed two vouchers on one nonce: only one can settle, and the other one is
    // already travelling. Accepting ours would be accepting a coin toss.
    final nonce = makeNonce();
    expect(await store.put(await sign('someone-else.near', nonce), VoucherKind.relayed, hops: 2), isTrue);
    expect(await store.put(await sign('merchant.near', nonce), VoucherKind.received), isFalse);
  });

  test('another signer cannot block a voucher by reusing its nonce', () async {
    // Nonces are public once gossiped. Keyed by nonce alone, anyone could squat on one with a
    // voucher of their own and make relays and the payee drop the real payment.
    final nonce = makeNonce();
    final squatter = await Ed25519().newKeyPair();
    final squat = await signVoucher(squatter, [Transfer('x.near', {usdcToken: '1'})],
        DateTime.now().add(const Duration(hours: 72)), nonce);
    expect(await store.put(squat, VoucherKind.relayed, hops: 1), isTrue);
    expect(await store.put(await sign('merchant.near', nonce), VoucherKind.received), isTrue);
  });

  // The first build stored a payee's accepted vouchers in an older table. Those are unsettled
  // claims on money: an app update must not lose them or stop the store opening.
  test('payments stored by the first version survive the upgrade', () async {
    final dir = Directory.systemTemp.createTempSync('nearby_store_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/old.db';
    final old = await openDatabase(path,
        version: 1,
        onCreate: (db, _) => db.execute('CREATE TABLE vouchers '
            '(nonce TEXT PRIMARY KEY, sent INTEGER NOT NULL, json TEXT NOT NULL, created_at INTEGER NOT NULL)'));
    await old.insert('vouchers', {'nonce': nonceId(voucher), 'sent': 0, 'json': jsonEncode(voucher), 'created_at': 1});
    await old.close();

    final upgraded = await VoucherStore.open(path);
    final kept = (await upgraded.all()).single;
    expect((kept.kind, kept.hops), (VoucherKind.received, 0));
    expect(kept.voucher, voucher);
    expect(await upgraded.put(voucher, VoucherKind.received), isFalse, reason: 'and it still cannot be accepted twice');
  });

  test('a voucher marked settled keeps its transaction and its place in the store', () async {
    await store.put(voucher, VoucherKind.received);
    await store.markSettled(voucher, 'tx1');
    // A later report without the hash (another relayer settled it) must not lose the link we had.
    await store.markSettled(voucher, null);

    final stored = (await store.all()).singleWhere((s) => voucherKey(s.voucher) == voucherKey(voucher));
    expect((stored.settled, stored.tx), (true, 'tx1'));
    expect(await store.put(voucher, VoucherKind.received), isFalse, reason: 'settled is still not a new payment');
  });

  test('payments stored before settlement was tracked survive the upgrade, as unsettled', () async {
    final dir = Directory.systemTemp.createTempSync('nearby_store_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/v2.db';
    final old = await openDatabase(path,
        version: 2,
        onCreate: (db, _) => db.execute('CREATE TABLE vouchers (key TEXT PRIMARY KEY, kind TEXT NOT NULL, '
            'hops INTEGER NOT NULL, json TEXT NOT NULL, created_at INTEGER NOT NULL)'));
    await old.insert('vouchers',
        {'key': voucherKey(voucher), 'kind': 'received', 'hops': 0, 'json': jsonEncode(voucher), 'created_at': 1});
    await old.close();

    final upgraded = await VoucherStore.open(path);
    final kept = (await upgraded.all()).single;
    expect((kept.kind, kept.settled, kept.tx), (VoucherKind.received, false, null));
    await upgraded.markSettled(voucher, 'tx1');
    expect((await upgraded.all()).single.tx, 'tx1');
  });

  test('lists what was stored', () async {
    await store.put(voucher, VoucherKind.sent);
    final stored = (await store.all()).singleWhere((s) => voucherKey(s.voucher) == voucherKey(voucher));
    // The payer re-shows this exact voucher instead of signing a second one for the same purchase.
    expect((stored.kind, stored.hops), (VoucherKind.sent, 0));
    expect(stored.voucher, voucher);
  });
}
