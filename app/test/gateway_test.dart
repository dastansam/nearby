import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearby/gateway.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late VoucherStore store;
  late List<List<dynamic>> uploads; // the vouchers of each request the relayer received

  setUp(() async {
    store = await VoucherStore.open(inMemoryDatabasePath);
    // The in-memory database is shared between tests in this file.
    for (final s in await store.all()) {
      await store.markSettled(s.voucher, null);
    }
    uploads = [];
  });

  /// A relayer that answers each voucher with [answer] (the shape relayer/src/settle.ts returns).
  Gateway gateway(Map<String, dynamic> Function(Map<String, dynamic> voucher) answer) => Gateway(
      store,
      'https://relayer.test',
      client: MockClient((request) async {
        expect((request.method, request.url.toString()), ('POST', 'https://relayer.test/vouchers'));
        final vouchers = jsonDecode(request.body)['vouchers'] as List;
        uploads.add(vouchers);
        return http.Response(jsonEncode({'results': vouchers.map((v) => answer(v)).toList()}), 200);
      }));

  Future<Map<String, dynamic>> voucher({Duration validFor = const Duration(hours: 72)}) async => signVoucher(
      await Ed25519().newKeyPair(), [Transfer('merchant.near', {usdcToken: '2500000'})], DateTime.now().add(validFor), makeNonce());

  Future<StoredVoucher> stored(Map<String, dynamic> v) async =>
      (await store.all()).singleWhere((s) => voucherKey(s.voucher) == voucherKey(v));

  // "The first phone with a signal settles for everyone": its own payments and the ones it carries.
  test('uploads everything the phone holds and records what settled', () async {
    final mine = await voucher(), carried = await voucher();
    await store.put(mine, VoucherKind.received);
    await store.put(carried, VoucherKind.relayed, hops: 3);

    await gateway((v) => {'status': 'settled', 'tx': 'tx-${v['payload']['nonce']}'}).sync();

    expect(uploads.single, unorderedEquals([mine, carried]), reason: 'exactly what was signed, or it cannot settle');
    expect((await stored(mine)).tx, 'tx-${mine['payload']['nonce']}');
    expect((await stored(carried)).settled, isTrue);
  });

  test('a settled voucher is not uploaded again', () async {
    // Every upload costs the relayer chain lookups, and phones sync every half minute.
    await store.put(await voucher(), VoucherKind.sent);
    final relayer = gateway((_) => {'status': 'settled', 'tx': 'tx1'});
    await relayer.sync();
    await relayer.sync();
    expect(uploads.length, 1);
  });

  test('a voucher the relayer could not settle yet stays pending and is sent again', () async {
    // "rejected" means the payer's balance is short today; "error" means the chain was unreachable.
    // Either way the payee is still owed, and a later try may succeed.
    final short = await voucher(), unlucky = await voucher();
    await store.put(short, VoucherKind.received);
    await store.put(unlucky, VoucherKind.received);
    var answers = {
      short['signature']: {'status': 'rejected', 'reason': 'insufficient balance or overflow'},
      unlucky['signature']: {'status': 'error', 'reason': 'fetch failed'},
    };
    final relayer = gateway((v) => answers[v['signature']]!);

    await relayer.sync();
    expect([(await stored(short)).settled, (await stored(unlucky)).settled], [false, false]);

    answers = {for (final s in answers.keys) s: {'status': 'settled', 'tx': 'tx9'}};
    await relayer.sync();
    expect([(await stored(short)).tx, (await stored(unlucky)).tx], ['tx9', 'tx9']);
  });

  test('an expired voucher is not uploaded', () async {
    // The contract refuses it for good, so sending it only wastes the signal.
    await store.put(await voucher(validFor: const Duration(seconds: -5)), VoucherKind.received);
    await gateway((_) => {'status': 'settled'}).sync();
    expect(uploads, isEmpty);
  });

  test('with no signal nothing is marked settled, and the failure is reported', () async {
    final v = await voucher();
    await store.put(v, VoucherKind.received);
    final offline = Gateway(store, 'https://relayer.test',
        client: MockClient((_) async => throw http.ClientException('Failed host lookup')));
    await expectLater(offline.sync(), throwsA(isA<http.ClientException>()));
    expect((await stored(v)).settled, isFalse);
  });

  // The demo's "C turns on data and the voucher settles": nobody presses anything.
  test('once started, a voucher that arrives while online is uploaded right away', () async {
    final first = Completer<void>(), second = Completer<void>();
    final relayer = gateway((v) {
      (first.isCompleted ? second : first).complete();
      return {'status': 'settled', 'tx': 'tx1'};
    });
    addTearDown(relayer.stop);
    await store.put(await voucher(), VoucherKind.relayed, hops: 1);
    relayer.start();
    await first.future;

    // Stored while the first upload may still be in flight: it must not wait half a minute.
    final arrived = await voucher();
    await store.put(arrived, VoucherKind.relayed, hops: 1);
    await second.future.timeout(const Duration(seconds: 5));
    expect(uploads.last, [arrived]);
  });

  test('an answer that does not cover every voucher settles none of them', () async {
    // Results are matched by position: one missing entry would mark the wrong payments as paid.
    final a = await voucher(), b = await voucher();
    await store.put(a, VoucherKind.received);
    await store.put(b, VoucherKind.received);
    final confused = Gateway(store, 'https://relayer.test',
        client: MockClient((_) async => http.Response(jsonEncode({'results': [{'status': 'settled', 'tx': 'tx1'}]}), 200)));
    await expectLater(confused.sync(), throwsStateError);
    expect([(await stored(a)).settled, (await stored(b)).settled], [false, false]);
  });
}
