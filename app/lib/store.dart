// Vouchers this phone has signed, accepted as payment, or is carrying for others.
import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'voucher/nep413.dart';

/// [sent] and [received] are this phone's own payments; [relayed] ones belong to other people
/// and are only carried toward the internet.
enum VoucherKind { sent, received, relayed }

/// What the relayer reported about a voucher: it is on chain, or it never will be.
enum Outcome { settled, failed }

/// [outcome] is null until the relayer has given a final answer; [tx] is the settling transaction
/// when it knew it.
typedef StoredVoucher = ({VoucherKind kind, int hops, Map<String, dynamic> voucher, Outcome? outcome, String? tx});

/// Whether a stored voucher can still settle: no final answer yet, and its deadline has not passed.
bool canSettle(StoredVoucher s, DateTime now) => s.outcome == null && voucherDeadline(s.voucher).isAfter(now);

class VoucherStore {
  final Database _db;
  // Sync, so listeners hear about a voucher before put() returns and in the order they were stored.
  final _puts = StreamController<StoredVoucher>.broadcast(sync: true);
  VoucherStore._(this._db);

  static const _outcomeColumns = ['outcome TEXT', 'tx TEXT'];
  static final _schema = 'CREATE TABLE vouchers (key TEXT PRIMARY KEY, kind TEXT NOT NULL, '
      'hops INTEGER NOT NULL, json TEXT NOT NULL, created_at INTEGER NOT NULL, ${_outcomeColumns.join(', ')})';

  static Future<VoucherStore> open([String path = 'nearby.db']) async => VoucherStore._(await openDatabase(path,
      version: 3,
      onCreate: (db, _) => db.execute(_schema),
      onUpgrade: (db, from, _) async {
        if (from == 2) {
          for (final column in _outcomeColumns) {
            await db.execute('ALTER TABLE vouchers ADD COLUMN $column');
          }
          return;
        }
        // Version 1 held only this phone's own payments, keyed by nonce. They are still unsettled
        // claims on money, so they are carried over rather than dropped.
        final old = await db.query('vouchers');
        await db.execute('DROP TABLE vouchers');
        await db.execute(_schema);
        for (final r in old) {
          await db.insert('vouchers', {
            'key': voucherKey(jsonDecode(r['json'] as String)),
            'kind': (r['sent'] == 1 ? VoucherKind.sent : VoucherKind.received).name,
            'hops': 0,
            'json': r['json'],
            'created_at': r['created_at'],
          });
        }
      }));

  /// Each voucher as it is stored or claimed, so the mesh can offer it and the screen can show it.
  Stream<StoredVoucher> get puts => _puts.stream;

  /// Stores a voucher under its signer and nonce. Returns false, changing nothing, if that slot
  /// is taken: the chain settles it once, so a voucher shown again is the same payment, not a
  /// second one, and a different voucher in the same slot means only one of the two can settle.
  ///
  /// One exception: a payment often reaches the payee over the mesh, as [VoucherKind.relayed],
  /// before they scan it. Storing that identical voucher as their own then succeeds.
  Future<bool> put(Map<String, dynamic> voucher, VoucherKind kind, {int hops = 0}) async {
    final key = voucherKey(voucher), json = jsonEncode(voucher);
    // The hop count the voucher is stored with, or null if it was not stored.
    final storedHops = await _db.transaction<int?>((txn) async {
      final held = await txn.query('vouchers', columns: ['kind', 'hops', 'json'], where: 'key = ?', whereArgs: [key]);
      if (held.isEmpty) {
        await txn.insert('vouchers', {
          'key': key,
          'kind': kind.name,
          'hops': hops,
          'json': json,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
        return hops;
      }
      final claim = held.single['kind'] == VoucherKind.relayed.name &&
          kind != VoucherKind.relayed &&
          held.single['json'] == json;
      if (claim) await txn.update('vouchers', {'kind': kind.name}, where: 'key = ?', whereArgs: [key]);
      return claim ? held.single['hops'] as int : null;
    });
    if (storedHops != null) _puts.add((kind: kind, hops: storedHops, voucher: voucher, outcome: null, tx: null));
    return storedHops != null;
  }

  /// Records the relayer's final answer for [voucher], with the settling [tx] if it knew one. The
  /// row stays, so the mesh still counts the voucher as held and does not fetch it again. A
  /// voucher recorded as settled stays settled, and keeps the transaction it has.
  Future<void> setOutcome(Map<String, dynamic> voucher, Outcome outcome, {String? tx}) => _db.rawUpdate(
      "UPDATE vouchers SET outcome = ?, tx = COALESCE(?, tx) WHERE key = ? AND outcome IS NOT 'settled'",
      [outcome.name, tx, voucherKey(voucher)]);

  Future<Set<String>> keys() async => {for (final r in await _db.query('vouchers', columns: ['key'])) r['key'] as String};

  /// Newest first.
  Future<List<StoredVoucher>> all() async => [
        for (final r in await _db.query('vouchers', orderBy: 'created_at DESC'))
          (
            kind: VoucherKind.values.byName(r['kind'] as String),
            hops: r['hops'] as int,
            voucher: jsonDecode(r['json'] as String) as Map<String, dynamic>,
            outcome: r['outcome'] == null ? null : Outcome.values.byName(r['outcome'] as String),
            tx: r['tx'] as String?,
          )
      ];
}
