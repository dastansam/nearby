// Balance attestations: the relayer's signed statement of what an offline account held at a point
// in time. A payee with no network accepts a voucher only up to this amount.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../store.dart';
import 'nep413.dart';

/// The relayer key whose attestations this build trusts ("ed25519:<base58>", printed by the
/// relayer's GET /). Set at build time: --dart-define=RELAYER_KEY=ed25519:...
/// Empty means no relayer is trusted, and balances cannot be checked at all.
///
/// Not const only so tests can stand in a relayer of their own.
String relayerKey = const String.fromEnvironment('RELAYER_KEY');

/// A payee stops trusting an attestation this long after the relayer read the balance.
const attestationLifetime = Duration(hours: 24);

/// Must match ATTESTATION_DOMAIN in relayer/src/attestation.ts.
const _domain = 'NearBy balance attestation v1\n';

typedef Attestation = ({String account, String token, BigInt balance, DateTime asOf});

/// Whether [a] is too old to accept payments against.
bool isStale(Attestation a, DateTime now) => a.asOf.add(attestationLifetime).isBefore(now);

/// The statement in [signed] ({payload, signature}) if the trusted relayer signed it, else null.
Future<Attestation?> readAttestation(dynamic signed) async {
  try {
    final payload = signed['payload'] as String;
    final ok = await Ed25519().verify(utf8.encode(_domain + payload),
        signature: Signature(untag(signed['signature']), publicKey: SimplePublicKey(untag(relayerKey), type: KeyPairType.ed25519)));
    if (!ok) return null;
    final a = jsonDecode(payload);
    return (
      account: a['account'] as String,
      token: a['token'] as String,
      balance: BigInt.parse(a['balance']),
      asOf: DateTime.parse(a['as_of']),
    );
  } catch (_) {
    return null;
  }
}

/// Stores [signed] if it is a genuine attestation and newer than the one held for that account.
/// Attestations arrive with vouchers, from the payer or a relay, so anything else is ignored.
Future<void> keepAttestation(VoucherStore store, dynamic signed) async {
  final a = await readAttestation(signed);
  if (a != null) await store.saveAttestation(a.account, a.asOf, signed as Map<String, dynamic>);
}

/// The freshest genuine attestation held for [account], or null.
Future<Attestation?> attestationFor(VoucherStore store, String account) async =>
    readAttestation(await store.attestation(account));
