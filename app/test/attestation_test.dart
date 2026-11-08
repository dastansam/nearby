import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/attestation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Produced by relayer/src/attestation.rs, which is pinned to the same file. If this stops
  // verifying, phones no longer trust what the relayer signs and refuse every payment.
  final vector = jsonDecode(File('../testdata/attestation-vector.json').readAsStringSync()) as Map<String, dynamic>;
  final signed = vector['signed'] as Map<String, dynamic>;

  setUp(() => relayerKey = vector['public_key'] as String);
  tearDown(() => relayerKey = '');

  test('reads an attestation the relayer signed', () async {
    final a = (await readAttestation(signed))!;
    expect((a.account, a.balance, a.asOf, a.block),
        (vector['attestation']['account'], BigInt.from(25000000), DateTime.utc(2026, 11, 10, 9), 223318485));
  });

  // A payee hands over goods against this number.
  test('refuses one whose balance was edited, or that another key signed', () async {
    final richer = {...signed, 'payload': (signed['payload'] as String).replaceFirst('25000000', '95000000')};
    expect(await readAttestation(richer), isNull);

    relayerKey = 'ed25519:7XjPPyUJBWM4k9icCaSX7mzNMXsj5mjiRdwWWUamiaWU';
    expect(await readAttestation(signed), isNull);
  });

  test('a build that trusts no relayer accepts no attestation', () async {
    relayerKey = '';
    expect(await readAttestation(signed), isNull);
  });

  test('what arrives in place of an attestation is ignored, not fatal', () async {
    // It comes off a QR code or the radio, from whoever is nearby.
    for (final junk in [null, 17, 'x', <String, dynamic>{}, {'payload': 5, 'signature': 'ed25519:1'}]) {
      expect(await readAttestation(junk), isNull, reason: '$junk');
    }
  });

  group('a settlement receipt', () {
    // Produced by relayer/src/attestation.rs too (same key). A phone with no signal drops a voucher
    // it is owed on the strength of this, so nothing but the relayer's own signature may do.
    final receiptVector = jsonDecode(File('../testdata/receipt-vector.json').readAsStringSync()) as Map<String, dynamic>;
    final signedReceipt = receiptVector['signed'] as Map<String, dynamic>;

    final voucher = {'signature': receiptVector['receipt']['voucher']};

    test('reads one the relayer signed', () async {
      final r = (await readReceipt(signedReceipt, voucher))!;
      expect((r.voucher, r.tx, r.block), (voucher['signature'], receiptVector['receipt']['tx'], 223318490));
    });

    test('refuses one for another voucher, and an attestation offered as a receipt', () async {
      expect(await readReceipt(signedReceipt, {'signature': 'ed25519:other'}), isNull);
      // Re-pointed at another voucher, with the signature kept: the signature no longer covers it.
      final edited = {...signedReceipt, 'payload': (signedReceipt['payload'] as String).replaceFirst('3s1dc5', '3s1dc6')};
      expect(await readReceipt(edited, {'signature': (voucher['signature'] as String).replaceFirst('3s1dc5', '3s1dc6')}), isNull);
      // Same key, different domain: a signature over one kind of statement must not pass for the other.
      expect(await readReceipt(signed, voucher), isNull);
      expect(await readAttestation(signedReceipt), isNull);
      expect(await readReceipt(null, voucher), isNull);
    });
  });

  test('the store keeps the freshest attestation for an account', () async {
    // Attestations travel with vouchers, so an old one can arrive after a new one. Falling back
    // to it would bring back a balance the payer has since spent.
    final store = await VoucherStore.open(inMemoryDatabasePath);
    Map<String, dynamic> tagged(String note) => {...signed, 'note': note};
    await store.saveAttestation('acct', DateTime.utc(2026, 11, 10, 9), tagged('new'));
    await store.saveAttestation('acct', DateTime.utc(2026, 11, 9, 9), tagged('old'));
    expect((await store.attestation('acct'))!['note'], 'new');
    await store.saveAttestation('acct', DateTime.utc(2026, 11, 10, 10), tagged('newer'));
    expect((await store.attestation('acct'))!['note'], 'newer');
    expect(await store.attestation('someone-else'), isNull);
  });
}
