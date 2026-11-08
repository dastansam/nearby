// A stand-in for the relayer's attestation key, for tests that need a balance the app will trust.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:nearby/voucher/guards.dart';
import 'package:nearby/voucher/nep413.dart';
import 'package:nearby/voucher/payment.dart';

/// [key]'s public half, in the form the app is built with (RELAYER_KEY).
Future<String> publicKeyOf(SimpleKeyPair key) async => tag((await key.extractPublicKey()).bytes);

/// What relayer/src/attestation.rs signs; testdata/attestation-vector.json pins the format.
/// [bond] defaults to just enough: most tests are about the balance.
Future<Map<String, dynamic>> signAttestation(SimpleKeyPair relayer, String account, String balance,
    {DateTime? asOf, int block = 1000, BigInt? bond}) async {
  final payload = jsonEncode({
    'account': account,
    'token': usdcToken,
    'balance': balance,
    'bond': (bond ?? minimumBond).toString(),
    'as_of': (asOf ?? DateTime.now()).toUtc().toIso8601String(),
    'block': block,
  });
  return _sign(relayer, 'NearBy balance attestation v1\n', payload);
}

/// The relayer's receipt for [voucher] settling; testdata/receipt-vector.json pins the format.
Future<Map<String, dynamic>> signReceipt(SimpleKeyPair relayer, Map<String, dynamic> voucher,
    {String tx = 'tx1', int block = 1000}) =>
    _sign(relayer, 'NearBy settlement receipt v1\n', jsonEncode({'voucher': voucher['signature'], 'tx': tx, 'block': block}));

Future<Map<String, dynamic>> _sign(SimpleKeyPair relayer, String domain, String payload) async {
  final signature = await Ed25519().sign(utf8.encode(domain + payload), keyPair: relayer);
  return {'payload': payload, 'signature': tag(signature.bytes)};
}
