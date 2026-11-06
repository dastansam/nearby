import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/store.dart';
import 'package:nearby/voucher/attestation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Produced by relayer/src/attestation.ts, which is pinned to the same file. If this stops
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
