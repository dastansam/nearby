import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nearby/gateway.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/attestation.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_relayer.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late VoucherStore store;
  late List<List<dynamic>> uploads; // the vouchers of each request the relayer received

  setUp(() async {
    store = await VoucherStore.open(inMemoryDatabasePath);
    // The in-memory database is shared between tests in this file: retire what earlier tests left,
    // as settled in a known block, which is the one state a gateway never asks about again.
    for (final s in await store.all()) {
      await store.setOutcome(s.voucher, Outcome.settled, block: 1);
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
    expect((await stored(carried)).outcome, Outcome.settled);
  });

  test('a settled voucher is not uploaded again', () async {
    // Every upload costs the relayer chain lookups, and phones sync every half minute.
    await store.put(await voucher(), VoucherKind.sent);
    final relayer = gateway((_) => {'status': 'settled', 'tx': 'tx1', 'block': 5000});
    await relayer.sync();
    await relayer.sync();
    expect(uploads.length, 1);
  });

  test('a settled voucher is asked about again until the relayer knows its block', () async {
    // Until then a payee cannot tell whether the payer's attested balance already includes it, and
    // has to count it against them. Left that way, an honest payer is short by that amount for good.
    final v = await voucher();
    await store.put(v, VoucherKind.received);
    Map<String, dynamic> answer = {'status': 'settled', 'tx': 'tx1'};
    final relayer = gateway((_) => answer);
    await relayer.sync();
    expect(((await stored(v)).outcome, (await stored(v)).settledBlock), (Outcome.settled, null));
    answer = {'status': 'settled', 'block': 5000};
    await relayer.sync();
    await relayer.sync();
    expect(uploads, [[v], [v]]);
    expect(((await stored(v)).tx, (await stored(v)).settledBlock), ('tx1', 5000));
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
    expect([(await stored(short)).outcome, (await stored(unlucky)).outcome], [null, null]);

    answers = {for (final s in answers.keys) s: {'status': 'settled', 'tx': 'tx9'}};
    await relayer.sync();
    expect([(await stored(short)).tx, (await stored(unlucky)).tx], ['tx9', 'tx9']);
  });

  test('an expired voucher is still asked about, because another phone may have settled it in time', () async {
    // Otherwise a payee who was offline past the deadline would see "expired" for money they received.
    final v = await voucher(validFor: const Duration(seconds: -5));
    await store.put(v, VoucherKind.received);
    await gateway((_) => {'status': 'settled'}).sync();
    expect((await stored(v)).outcome, Outcome.settled);
  });

  test('a voucher the relayer says will never settle is not sent again', () async {
    // "invalid" is final (expired unsettled, or its nonce went to another voucher). Without this,
    // every phone carrying it would upload it every half minute until its deadline.
    final v = await voucher();
    await store.put(v, VoucherKind.received);
    final relayer = gateway((_) => {'status': 'invalid', 'reason': 'nonce spent by another voucher'});
    await relayer.sync();
    await relayer.sync();
    expect(uploads.length, 1);
    expect((await stored(v)).outcome, Outcome.failed);
  });

  test('a relayer address with a trailing slash still reaches the upload endpoint', () async {
    await store.put(await voucher(), VoucherKind.sent);
    Uri? asked;
    await Gateway(store, 'https://relayer.test/', client: MockClient((request) async {
      asked = request.url;
      return http.Response(jsonEncode({'results': [{'status': 'settled'}]}), 200);
    })).sync();
    expect(asked.toString(), 'https://relayer.test/vouchers');
  });

  // "No signal" is normal and needs no action. A wrong address or a broken relayer is not, and
  // on a phone with working internet it would otherwise look exactly the same.
  test('a relayer fault is not reported as having no signal', () async {
    await store.put(await voucher(), VoucherKind.sent);
    Future<String?> problemWith(MockClient client) async {
      final attempted = Completer<void>();
      final relayer = Gateway(store, 'https://relayer.test', client: client, onChange: attempted.complete);
      relayer.start();
      await attempted.future;
      await relayer.stop();
      return relayer.problem;
    }

    expect(await problemWith(MockClient((_) async => throw http.ClientException('Failed host lookup'))), 'No signal');
    expect(await problemWith(MockClient((_) async => http.Response('Not Found', 404))), contains('404'));
  });

  test('with no signal nothing is marked settled, and the failure is reported', () async {
    final v = await voucher();
    await store.put(v, VoucherKind.received);
    final offline = Gateway(store, 'https://relayer.test',
        client: MockClient((_) async => throw http.ClientException('Failed host lookup')));
    await expectLater(offline.sync(), throwsA(isA<http.ClientException>()));
    expect((await stored(v)).outcome, isNull);
  });

  // The demo's "C turns on data and the voucher settles": nobody presses anything.
  test('once started, a voucher that arrives while online is uploaded right away', () async {
    final first = Completer<void>(), second = Completer<void>();
    final relayer = gateway((v) {
      (first.isCompleted ? second : first).complete();
      return {'status': 'settled', 'tx': 'tx1', 'block': 5000};
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


  group('the balance attestation', () {
    const account = 'payer.near';
    late VoucherStore mine;
    late List<String> fetched;

    setUp(() async {
      final dir = Directory.systemTemp.createTempSync('nearby_gateway_');
      addTearDown(() => dir.deleteSync(recursive: true));
      mine = await VoucherStore.open('${dir.path}/mine.db');
      fetched = [];
    });
    tearDown(() => relayerKey = '');

    /// One attempt, as the app makes them, against a relayer with nothing to settle that attests 5 USDC.
    Future<void> attempt({bool trusted = true}) async {
      final relayer = await Ed25519().newKeyPair();
      relayerKey = trusted ? await publicKeyOf(relayer) : '';
      final done = Completer<void>();
      final g = Gateway(mine, 'https://relayer.test',
          account: account,
          onChange: () => done.isCompleted ? null : done.complete(),
          client: MockClient((request) async {
            if (request.method == 'POST') return http.Response(jsonEncode({'results': []}), 200);
            fetched.add(request.url.toString());
            return http.Response(jsonEncode(await signAttestation(relayer, account, '5000000')), 200);
          }));
      g.start();
      await done.future.timeout(const Duration(seconds: 5));
      g.stop();
      expect(g.problem, isNull);
    }

    // Without one, this phone's payments are refused everywhere once it leaves coverage, so it
    // is fetched whenever the relayer is reachable, without the user asking.
    test('is fetched for this phone\'s account whenever the relayer is reachable', () async {
      await attempt();
      expect(fetched, ['https://relayer.test/attestation/$account']);
      expect((await attestationFor(mine, account))!.balance, BigInt.from(5000000));
    });

    test('signed by a key this build does not trust is reported, not quietly dropped', () async {
      // A build with a mistyped RELAYER_KEY would otherwise say "go online" forever, with nothing to explain it.
      relayerKey = await publicKeyOf(await Ed25519().newKeyPair());
      final other = await Ed25519().newKeyPair();
      final g = Gateway(mine, 'https://relayer.test',
          account: account,
          client: MockClient((_) async => http.Response(jsonEncode(await signAttestation(other, account, '5000000')), 200)));
      await expectLater(g.refreshAttestation(), throwsStateError);
      expect(await mine.attestation(account), isNull);
    });

    test('is not fetched by a build that trusts no relayer, which could not check it', () async {
      await attempt(trusted: false);
      expect(fetched, isEmpty);
    });
  });

  test('an answer that does not cover every voucher settles none of them', () async {
    // Results are matched by position: one missing entry would mark the wrong payments as paid.
    final a = await voucher(), b = await voucher();
    await store.put(a, VoucherKind.received);
    await store.put(b, VoucherKind.received);
    final confused = Gateway(store, 'https://relayer.test',
        client: MockClient((_) async => http.Response(jsonEncode({'results': [{'status': 'settled', 'tx': 'tx1'}]}), 200)));
    await expectLater(confused.sync(), throwsStateError);
    expect([(await stored(a)).outcome, (await stored(b)).outcome], [null, null]);
  });
}
