import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/voucher/nep413.dart';

void main() {
  // intents.near verifies the exact bytes the relayer signs (checked against mainnet
  // simulate_intents). If the Dart signer drifts by one byte, every phone-signed voucher is
  // rejected at settlement, long after the payee accepted it. The shared vector pins both sides.
  test('signs the same voucher as the relayer (the shared vector)', () async {
    final vector = jsonDecode(File('../testdata/voucher-vector.json').readAsStringSync());
    final key = await Ed25519().newKeyPairFromSeed(hex.decode(vector['seed_hex']));
    final t = vector['message']['intents'][0];

    final voucher = await signVoucher(
      key,
      [Transfer(t['receiver_id'], Map<String, String>.from(t['tokens']), memo: t['memo'])],
      DateTime.parse(vector['message']['deadline']),
      Uint8List.fromList(hex.decode(vector['nonce_hex'])),
    );

    expect(voucher, vector['voucher']);
  });

  test('nonces are 32 bytes and never repeat', () {
    // The chain settles each nonce once, so a repeated one would make the second voucher unsettleable.
    final a = makeNonce(), b = makeNonce();
    expect(a.length, 32);
    expect(a, isNot(b));
  });
}
