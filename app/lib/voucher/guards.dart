// What a payee can check about a payer with no network. Offline double-spending cannot be
// prevented, only bounded (a cap, and an attested balance minus what has been seen) and proven
// (a sequence number per voucher: two vouchers with one number are proof of cheating).
import 'dart:convert';

import '../store.dart';
import 'attestation.dart';
import 'nep413.dart';
import 'payment.dart';

/// No single offline payment above 25 USDC: the most one bad voucher can cost a payee.
final paymentCap = BigInt.from(25000000);

/// The least a payer must have locked in the bond contract to be paid offline: what cheating costs
/// them. A policy knob, in whole NEAR; the bond is in NEAR because that is what any account can
/// receive, and the budget in USDC, so the two are not compared. `MIN_BOND_NEAR` sets it for one
/// build: the contract takes no bond under 1 NEAR.
const minimumBondNear = int.fromEnvironment('MIN_BOND_NEAR', defaultValue: 5);
final minimumBond = BigInt.from(minimumBondNear) * BigInt.from(10).pow(24);

/// The payer chooses the deadline. One far off would let them unbond and withdraw (7 days in the
/// contract) before a voucher held back on purpose could be slashed. [voucherLifetime] is what the
/// app signs; the hour is for the two phones' clocks.
final maxVoucherLife = voucherLifetime + const Duration(hours: 1);

/// The value of entry [name] in a voucher's memo ("req:9f2c seq:17 prev:00"), or null.
String? memoEntry(Map<String, dynamic> v, String name) =>
    memoEntries(v).where((e) => e.startsWith('$name:')).map((e) => e.substring(name.length + 1)).firstOrNull;

/// When [v] expires; the signature check has already made sure this parses.
DateTime _deadline(Map<String, dynamic> v) => DateTime.parse(jsonDecode(v['payload']['message'])['deadline']);

/// A voucher's sequence number. Only the one plain spelling counts: the relayer pairs double-spends
/// by the text of the number, so "5" and "05" must not both be accepted as the fifth voucher.
int? _seq(Map<String, dynamic> v) {
  final seq = memoEntry(v, 'seq') ?? '';
  return RegExp(r'^[1-9][0-9]*$').hasMatch(seq) ? int.tryParse(seq) : null;
}

/// USDC that [v] would move out of its signer's balance. Read defensively: a relayed voucher
/// has only had its signature checked, so its contents can be anything.
BigInt usdcOut(Map<String, dynamic> v) {
  try {
    var total = BigInt.zero;
    for (final intent in jsonDecode(v['payload']['message'])['intents'] as List) {
      final amount = intent['intent'] == 'transfer' ? intent['tokens'][usdcToken] : null;
      // Digits only: a "negative amount" must not add to what the payer appears to have left.
      if (amount is String && RegExp(r'^[0-9]+$').hasMatch(amount)) total += BigInt.parse(amount);
    }
    return total;
  } catch (_) {
    return BigInt.zero;
  }
}

/// What a payer can still spend as far as this phone can tell: the attested balance minus every
/// voucher of theirs seen here ([theirs]) that the balance does not already reflect.
BigInt spendable(Attestation a, Iterable<StoredVoucher> theirs) =>
    theirs.fold(a.balance, (left, s) => _reflected(s, a) ? left : left - usdcOut(s.voucher));

/// A voucher that never will move money, or that had moved it by the block the balance was read
/// at, is already accounted for. Anything else may still come out of that balance, including one
/// reported settled with no block yet (assume the worst: after the reading).
bool _reflected(StoredVoucher s, Attestation a) =>
    s.outcome == Outcome.failed ||
    (s.outcome == Outcome.settled && s.settledBlock != null && s.settledBlock! <= a.block);

/// The sequence number and "prev" fingerprint for a payer's next voucher, given the ones
/// they have signed ([mine]). The chain lets anyone prove a double-spend; it never orders settlement.
({int seq, String prev}) nextSequence(Iterable<StoredVoucher> mine) {
  var seq = 0, prev = '00';
  for (final s in mine) {
    final n = _seq(s.voucher) ?? 0;
    if (n > seq) (seq, prev) = (n, voucherHash(s.voucher));
  }
  return (seq: seq + 1, prev: prev);
}

/// Why a payee should refuse [voucher], or null. The voucher is already known to pay the request
/// (checkPayment); this looks at the payer: every voucher of theirs this phone holds ([theirs])
/// and the freshest [attestation] of their balance.
///
/// A build that trusts no relayer ([relayerKey] empty) has no balance it could believe, and checks
/// only the cap and the sequence chain.
String? checkGuards(
  Map<String, dynamic> voucher, {
  required Attestation? attestation,
  required Iterable<StoredVoucher> theirs,
  required DateTime now,
}) {
  final amount = usdcOut(voucher);
  if (amount > paymentCap) return 'cap';
  if (_deadline(voucher).isAfter(now.add(maxVoucherLife))) return 'deadline';

  final seq = _seq(voucher);
  if (seq == null) return 'sequence';
  final others = theirs.where((s) => s.voucher['signature'] != voucher['signature']).toList();
  for (final s in others) {
    // One number, two vouchers: the payer has signed away the same place in their chain twice.
    if (_seq(s.voucher) == seq) return 'double-spend';
    // We hold their previous voucher, and this one claims to follow a different one.
    if (_seq(s.voucher) == seq - 1 && memoEntry(voucher, 'prev') != voucherHash(s.voucher)) return 'sequence';
  }
  if (relayerKey.isEmpty) return null;

  if (attestation == null || attestation.account != signerOf(voucher) || attestation.token != usdcToken) return 'attestation';
  if (isStale(attestation, now)) return 'stale';
  if (attestation.bond < minimumBond) return 'bond';
  return spendable(attestation, others) < amount ? 'balance' : null;
}

/// What to tell the payee for each refusal from [checkGuards].
final guardRefusals = {
  'cap': 'over the limit of ${formatUsdc(paymentCap.toString())} for one offline payment',
  'deadline': 'the payment stays valid for more than ${voucherLifetime.inHours} h',
  'sequence': 'broken payment sequence',
  'double-spend': 'double-spend: the payer already used this sequence number',
  'attestation': 'no valid balance attestation from the payer',
  'stale': 'the payer\'s balance attestation is older than ${attestationLifetime.inHours} h',
  'bond': 'the payer has less than $minimumBondNear NEAR bonded against cheating',
  'balance': 'insufficient attested balance',
};
