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

/// Must match ATTESTATION_DOMAIN and RECEIPT_DOMAIN in relayer/src/attestation.rs.
const _attestationDomain = 'NearBy balance attestation v1\n';
const _receiptDomain = 'NearBy settlement receipt v1\n';

/// [asOf] is the relayer's clock, for how long the statement is good. [block] is the height the
/// balance was read at, for what it includes: every payment settled by that block, and none after.
/// [bond] is the yoctoNEAR locked in the bond contract against the payer cheating: what a
/// double-spend costs them, over and above the key.
typedef Attestation = ({String account, String token, BigInt balance, BigInt bond, DateTime asOf, int block});

/// Whether [a] is too old to accept payments against.
bool isStale(Attestation a, DateTime now) => a.asOf.add(attestationLifetime).isBefore(now);

/// The relayer's word that the voucher with signature [voucher] settled, in [tx] by [block].
typedef Receipt = ({String voucher, String tx, int block});

/// The statement in [signed] ({payload, signature}) if the trusted relayer signed it, else null.
Future<Attestation?> readAttestation(dynamic signed) async {
  try {
    final a = jsonDecode(await _statement(_attestationDomain, signed));
    return (
      account: a['account'] as String,
      token: a['token'] as String,
      balance: BigInt.parse(a['balance']),
      bond: BigInt.parse(a['bond']),
      asOf: DateTime.parse(a['as_of']),
      block: a['block'] as int,
    );
  } catch (_) {
    return null;
  }
}

/// The receipt in [signed] ({payload, signature}) if the trusted relayer signed it for [voucher], else null.
Future<Receipt?> readReceipt(dynamic signed, Map<String, dynamic> voucher) async {
  try {
    final r = jsonDecode(await _statement(_receiptDomain, signed));
    if (r['voucher'] != voucher['signature']) return null;
    return (voucher: r['voucher'] as String, tx: r['tx'] as String, block: r['block'] as int);
  } catch (_) {
    return null;
  }
}

/// Marks [voucher] settled in the store on the strength of [signed], if it is the relayer's receipt
/// for it. What is kept is the receipt alone, not whatever came around it, for passing on. Returns
/// whether it was.
Future<bool> keepReceipt(VoucherStore store, Map<String, dynamic> voucher, dynamic signed) async {
  final r = await readReceipt(signed, voucher);
  if (r == null) return false;
  await store.setOutcome(voucher, Outcome.settled,
      tx: r.tx, block: r.block, receipt: {'payload': signed['payload'], 'signature': signed['signature']});
  return true;
}

/// The payload of [signed], once the trusted relayer's signature over [domain] + payload checks out. Throws otherwise.
Future<String> _statement(String domain, dynamic signed) async {
  if (relayerKey.isEmpty) throw StateError('this build trusts no relayer');
  final payload = signed['payload'] as String;
  final ok = await Ed25519().verify(utf8.encode(domain + payload),
      signature: Signature(untag(signed['signature']), publicKey: SimplePublicKey(untag(relayerKey), type: KeyPairType.ed25519)));
  if (!ok) throw StateError('not signed by the trusted relayer');
  return payload;
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
