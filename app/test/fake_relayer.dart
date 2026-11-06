// A stand-in for the relayer's attestation key, for tests that need a balance the app will trust.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';

/// [key]'s public half, in the form the app is built with (RELAYER_KEY).
Future<String> publicKeyOf(SimpleKeyPair key) async => tag((await key.extractPublicKey()).bytes);

/// What relayer/src/attestation.ts signs; testdata/attestation-vector.json pins the format.
Future<Map<String, dynamic>> signAttestation(SimpleKeyPair relayer, String account, String balance, {DateTime? asOf}) async {
  final payload = jsonEncode({
    'account': account,
    'token': usdcToken,
    'balance': balance,
    'bond': '0',
    'as_of': (asOf ?? DateTime.now()).toUtc().toIso8601String(),
  });
  final signature = await Ed25519().sign(utf8.encode('NearBy balance attestation v1\n$payload'), keyPair: relayer);
  return {'payload': payload, 'signature': tag(signature.bytes)};
}
