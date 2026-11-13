import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/screens/receive.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/attestation.dart';
import 'package:nearby/voucher/guards.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_relayer.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final now = DateTime.utc(2026, 11, 11, 12); // every voucher and check below is dated from this
  final readAt = now.subtract(const Duration(hours: 2)); // when the relayer read the payer's balance
  const readBlock = 5000; // and the block it read it at
  late SimpleKeyPair payer;
  late String payerId;

  setUp(() async {
    payer = await Ed25519().newKeyPair();
    payerId = implicitAccount((await payer.extractPublicKey()).bytes);
    relayerKey = 'ed25519:some-relayer'; // a build that trusts one; these tests hand the guards its statements directly
  });
  tearDown(() => relayerKey = '');

  PaymentRequest request(String amount) =>
      PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: amount, id: newRequestId());

  Future<Map<String, dynamic>> pay(String amount, {int seq = 1, String prev = '00', String to = 'merchant.near'}) =>
      signPayment(payer, PaymentRequest(receiverId: to, token: usdcToken, amount: amount, id: newRequestId()),
          seq: seq, prev: prev, now: now);

  StoredVoucher seen(Map<String, dynamic> v, {Outcome? outcome, int? settledBlock}) =>
      (kind: VoucherKind.relayed, hops: 1, voucher: v, outcome: outcome, tx: null, settledBlock: settledBlock);

  Attestation attested(String balance, {DateTime? asOf, String? account, BigInt? bond}) => (
        account: account ?? payerId,
        token: usdcToken,
        balance: BigInt.parse(balance),
        bond: bond ?? minimumBond,
        asOf: asOf ?? readAt,
        block: readBlock
      );

  String? refusal(Map<String, dynamic> v, {Attestation? a, List<StoredVoucher> theirs = const []}) =>
      checkGuards(v, attestation: a, theirs: theirs, now: now);

  // Layer 1 of the double-spend model. Offline, a payee cannot know the payer's balance; they
  // can know what the relayer signed a while ago and what the payer has spent in front of them since.
  group('a payee accepts at most the attested balance minus what they have seen spent', () {
    test('accepts a payment the attested balance covers', () async {
      expect(refusal(await pay('2500000'), a: attested('3000000')), isNull);
    });

    test('refuses the same funds a second time', () async {
      // The demo's step 5: 3 USDC attested, 2.50 already paid here, another 2.50 offered.
      final first = await pay('2500000');
      final second = await pay('2500000', seq: 2, prev: voucherHash(first));
      expect(refusal(second, a: attested('3000000'), theirs: [seen(first)]), 'balance');
    });

    test('counts payments to other people that reached this phone over the mesh', () async {
      final elsewhere = await pay('2000000', to: 'other.near');
      final here = await pay('2000000', seq: 2, prev: voucherHash(elsewhere));
      expect(refusal(here, a: attested('3000000'), theirs: [seen(elsewhere)]), 'balance');
    });

    test('does not count a payment the balance already reflects', () async {
      // A returning customer: yesterday's payment settled before the relayer read today's balance.
      // Subtracting it again would refuse an honest payer every time they come back.
      final old = await pay('2500000');
      final today = await pay('2500000', seq: 2, prev: voucherHash(old));
      for (final block in [readBlock - 900, readBlock]) {
        final settledBy = seen(old, outcome: Outcome.settled, settledBlock: block);
        expect(refusal(today, a: attested('2500000'), theirs: [settledBy]), isNull, reason: 'settled by block $block');
      }
    });

    test('counts a payment that settled after the balance was read, or in an unknown block', () async {
      // The attested number is from before that money left, so it is still too high by that much.
      // One block is enough: the relayer may have read the balance from a node a block behind.
      final old = await pay('2500000');
      final next = await pay('2500000', seq: 2, prev: voucherHash(old));
      final after = seen(old, outcome: Outcome.settled, settledBlock: readBlock + 1);
      expect(refusal(next, a: attested('3000000'), theirs: [after]), 'balance');
      expect(refusal(next, a: attested('3000000'), theirs: [seen(old, outcome: Outcome.settled)]), 'balance');
    });

    test('does not count a payment that will never settle', () async {
      final dead = await pay('2500000');
      final next = await pay('2500000', seq: 2, prev: voucherHash(dead));
      expect(refusal(next, a: attested('3000000'), theirs: [seen(dead, outcome: Outcome.failed)]), isNull);
    });

    test('a voucher for a negative amount does not add to what the payer has left', () async {
      // Anyone can sign nonsense and let the mesh carry it. Counted as written, "-25 USDC spent"
      // would turn an empty account into one good for 25.
      final junk = await signVoucher(payer, [Transfer('x.near', {usdcToken: '-25000000'}, memo: 'seq:1 prev:00')],
          now.add(const Duration(hours: 72)), makeNonce());
      final real = await pay('25000000', seq: 2, prev: voucherHash(junk));
      expect(refusal(real, a: attested('0'), theirs: [seen(junk)]), 'balance');
    });

    test('showing the same voucher again does not count it against itself', () async {
      final v = await pay('2500000');
      expect(refusal(v, a: attested('3000000'), theirs: [seen(v)]), isNull);
    });

    test('refuses when there is no attestation, or it is for another account', () async {
      final v = await pay('2500000');
      expect(refusal(v), 'attestation');
      expect(refusal(v, a: attested('3000000', account: 'f' * 64)), 'attestation');
    });

    test('refuses an attestation older than a day', () async {
      // The longer since the reading, the more the payer may have spent where this phone cannot see.
      final v = await pay('2500000');
      expect(refusal(v, a: attested('3000000', asOf: now.subtract(const Duration(hours: 25)))), 'stale');
      expect(refusal(v, a: attested('3000000', asOf: now.subtract(const Duration(hours: 23)))), isNull);
    });

    // Layer 3: without a bond, a double-spend costs the payer nothing but a key. The relayer
    // reports 0 for a key that is banned or whose bond is being withdrawn, so this covers those too.
    test('refuses a payer who has not bonded enough NEAR against cheating', () async {
      final v = await pay('2500000');
      expect(refusal(v, a: attested('3000000', bond: minimumBond - BigInt.one)), 'bond');
      expect(refusal(v, a: attested('3000000', bond: BigInt.zero)), 'bond');
      expect(refusal(v, a: attested('3000000', bond: minimumBond)), isNull);
    });

    // The bond can be withdrawn 7 days after notice. A voucher valid for longer could be held back
    // and settled once there is nothing left to slash.
    test('refuses a payment that stays valid for longer than the app ever signs', () async {
      final a = attested('9000000');
      final request = PaymentRequest(receiverId: 'merchant.near', token: usdcToken, amount: '1000000', id: newRequestId());
      final longLived = await signVoucher(payer, [Transfer('merchant.near', {usdcToken: '1000000'}, memo: 'req:${request.id} seq:1 prev:00')],
          now.add(const Duration(hours: 74)), makeNonce());
      expect(refusal(longLived, a: a), 'deadline');
      final usual = await signVoucher(payer, [Transfer('merchant.near', {usdcToken: '1000000'}, memo: 'req:${request.id} seq:1 prev:00')],
          now.add(const Duration(hours: 72)), makeNonce());
      expect(refusal(usual, a: a), isNull);
    });

    test('refuses a payment over the cap however large the balance', () async {
      // The cap is what one bad voucher can cost a payee. 25 USDC is allowed, a cent more is not.
      expect(refusal(await pay('25000000'), a: attested('900000000')), isNull);
      expect(refusal(await pay('25010000'), a: attested('900000000')), 'cap');
    });
  });

  // Layer 2: every voucher has a place in its payer's chain. Two vouchers in one place are a
  // self-contained proof of cheating that the bond contract can check.
  group('the sequence chain', () {
    test('a second voucher with a sequence number already seen is a double-spend', () async {
      final first = await pay('1000000', seq: 4, prev: 'aa');
      final twin = await pay('1000000', seq: 4, prev: 'aa', to: 'other.near');
      expect(refusal(twin, a: attested('9000000'), theirs: [seen(first)]), 'double-spend');
    });

    test('a voucher with no sequence number is refused', () async {
      final v = await signVoucher(payer, [Transfer('merchant.near', {usdcToken: '1000000'}, memo: 'req:aa')],
          now.add(const Duration(hours: 72)), makeNonce());
      expect(refusal(v, a: attested('9000000')), 'sequence');
    });

    test('a sequence number spelled any other way than plainly is refused', () async {
      // The relayer pairs double-spends by the number as written. If "05" were accepted as 5, a
      // payer could spend place 5 twice and the two vouchers would never be matched up.
      for (final spelling in ['05', '+5', '0x5', '5.0', '0', '-1']) {
        final v = await signVoucher(payer, [Transfer('merchant.near', {usdcToken: '1000000'}, memo: 'req:aa seq:$spelling prev:aa')],
            now.add(const Duration(hours: 72)), makeNonce());
        expect(refusal(v, a: attested('9000000')), 'sequence', reason: spelling);
      }
    });

    test('a voucher that claims to follow a different voucher than the one held is refused', () async {
      // The payer signed two vouchers numbered 3: the one this phone holds and the one named here.
      final third = await pay('1000000', seq: 3, prev: 'aa');
      final fourth = await pay('1000000', seq: 4, prev: '0123456789abcdef');
      expect(refusal(fourth, a: attested('9000000'), theirs: [seen(third)]), 'sequence');
      expect(refusal(await pay('1000000', seq: 4, prev: voucherHash(third)), a: attested('9000000'), theirs: [seen(third)]),
          isNull);
    });

    test('a payer numbers each new voucher after their last and names it', () async {
      expect(nextSequence([]), (seq: 1, prev: '00'));
      final first = await pay('1000000'), second = await pay('1000000', seq: 2, prev: voucherHash(first));
      expect(nextSequence([seen(second), seen(first)]), (seq: 3, prev: voucherHash(second)));
    });

    test('a build that trusts no relayer still enforces the chain and the cap', () async {
      relayerKey = '';
      final first = await pay('1000000');
      expect(refusal(await pay('1000000')), isNull);
      expect(refusal(await pay('1000000', to: 'other.near'), theirs: [seen(first)]), 'double-spend');
      expect(refusal(await pay('26000000')), 'cap');
    });
  });

  // The same rules through the door the receive screen uses, against a real store.
  group('at the till', () {
    late VoucherStore store;
    late SimpleKeyPair relayer;
    late Directory dir;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('nearby_guards_');
      store = await VoucherStore.open('${dir.path}/till.db');
      relayer = await Ed25519().newKeyPair();
      relayerKey = await publicKeyOf(relayer);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<Map<String, dynamic>> attestation(String balance, {SimpleKeyPair? signedBy}) =>
        signAttestation(signedBy ?? relayer, payerId, balance);

    Future<String?> offer(PaymentRequest r, Map<String, dynamic> v, {Map<String, dynamic>? a}) =>
        acceptPayment(store, r, jsonEncode({'v': v, if (a != null) 'a': a}));

    test('the payer cannot spend the same funds twice at one payee', () async {
      final a = await attestation('3000000');
      final r1 = request('2500000'), r2 = request('2500000');
      final first = await signPayment(payer, r1);
      expect(await offer(r1, first, a: a), isNull);
      expect(await offer(r2, await signPayment(payer, r2, seq: 2, prev: voucherHash(first)), a: a), 'balance');
    });

    test('an attestation the trusted relayer did not sign is worth nothing', () async {
      // Anyone can write "balance: 1000000000" and sign it with a key of their own.
      final r = request('2500000');
      final forged = await attestation('1000000000', signedBy: await Ed25519().newKeyPair());
      expect(await offer(r, await signPayment(payer, r), a: forged), 'attestation');
    });

    test('the refused half of a double-spend is carried on as proof', () async {
      // The payee is not paid, but the voucher still has to reach the relayer: it is half of the
      // evidence that slashes the payer's bond.
      final a = await attestation('9000000');
      final r1 = request('1000000'), r2 = request('1000000');
      expect(await offer(r1, await signPayment(payer, r1, seq: 7, prev: 'aa'), a: a), isNull);
      final twin = await signPayment(payer, r2, seq: 7, prev: 'aa');
      expect(await offer(r2, twin, a: a), 'double-spend');
      final kept = (await store.from(payerId)).singleWhere((s) => s.voucher['signature'] == twin['signature']);
      expect(kept.kind, VoucherKind.relayed);
    });
  });
}
