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

/// [outcome] is null until the relayer has given a final answer. [tx] is the settling transaction
/// and [settledBlock] a block height by which it had settled, when the relayer knew them.
typedef StoredVoucher = ({
  VoucherKind kind,
  int hops,
  Map<String, dynamic> voucher,
  Outcome? outcome,
  String? tx,
  int? settledBlock,
});

/// Whether a stored voucher can still settle: no final answer yet, and its deadline has not passed.
bool canSettle(StoredVoucher s, DateTime now) => s.outcome == null && voucherDeadline(s.voucher).isAfter(now);

class VoucherStore {
  final Database _db;
  // Sync, so listeners hear about a voucher before put() returns and in the order they were stored.
  final _puts = StreamController<StoredVoucher>.broadcast(sync: true);
  final _outcomes = StreamController<StoredVoucher>.broadcast(sync: true);
  VoucherStore._(this._db);

  static Future<VoucherStore> open([String path = 'nearby.db']) async => VoucherStore._(
      await openDatabase(path, version: 5, onCreate: (db, _) => _migrate(db, 0), onUpgrade: (db, from, _) => _migrate(db, from)));

  /// Brings a database at version [from] (0: empty) up to date, one version's changes at a time.
  static Future<void> _migrate(Database db, int from) async {
    if (from < 2) {
      // Version 1 held only this phone's own payments, keyed by nonce. They are still unsettled
      // claims on money, so they are carried over rather than dropped.
      final old = from == 1 ? await db.query('vouchers') : const <Map<String, Object?>>[];
      await db.execute('DROP TABLE IF EXISTS vouchers');
      await db.execute('CREATE TABLE vouchers (key TEXT PRIMARY KEY, kind TEXT NOT NULL, hops INTEGER NOT NULL, '
          'json TEXT NOT NULL, created_at INTEGER NOT NULL)');
      for (final r in old) {
        await db.insert('vouchers', {
          'key': voucherKey(jsonDecode(r['json'] as String)),
          'kind': (r['sent'] == 1 ? VoucherKind.sent : VoucherKind.received).name,
          'hops': 0,
          'json': r['json'],
          'created_at': r['created_at'],
        });
      }
    }
    if (from < 3) {
      await db.execute('ALTER TABLE vouchers ADD COLUMN outcome TEXT');
      await db.execute('ALTER TABLE vouchers ADD COLUMN tx TEXT');
    }
    if (from < 4) {
      await db.execute('ALTER TABLE vouchers ADD COLUMN settled_block INTEGER');
      await db.execute('CREATE TABLE attestations (account TEXT PRIMARY KEY, as_of INTEGER NOT NULL, json TEXT NOT NULL)');
    }
    if (from < 5) {
      await db.execute('ALTER TABLE vouchers ADD COLUMN receipt TEXT');
    }
  }

  /// Each voucher as it is stored or claimed, so the mesh can offer it and the screen can show it.
  Stream<StoredVoucher> get puts => _puts.stream;

  /// Each voucher as it stands after the relayer's answer about it is recorded, so a screen showing
  /// it as pending can show it settled, or not.
  Stream<StoredVoucher> get outcomes => _outcomes.stream;

  /// Vouchers the relayer turned down for now, with its reason (the payer's balance is short, say).
  /// Nothing is stored: the voucher may still settle, and is uploaded again. The screen showing it
  /// as pending should say what the chain said.
  Stream<({Map<String, dynamic> voucher, String reason})> get rejections => _rejections.stream;
  final _rejections = StreamController<({Map<String, dynamic> voucher, String reason})>.broadcast(sync: true);
  void noteRejection(Map<String, dynamic> voucher, String reason) => _rejections.add((voucher: voucher, reason: reason));

  /// Stores a voucher under its signer and nonce. Returns false, changing nothing, if that slot
  /// is taken: the chain settles it once, so a voucher shown again is the same payment, not a
  /// second one, and a different voucher in the same slot means only one of the two can settle.
  ///
  /// One exception: a payment often reaches the payee over the mesh, as [VoucherKind.relayed],
  /// before they scan it. Storing that identical voucher as their own then succeeds.
  Future<bool> put(Map<String, dynamic> voucher, VoucherKind kind, {int hops = 0}) async {
    final key = voucherKey(voucher), json = jsonEncode(voucher);
    // The voucher as stored, or null if it was not. Built from what the transaction read, and
    // told to listeners straight after it: transactions run one at a time, so nothing awaited in
    // between can let a later put() tell its listeners first.
    final stored = await _db.transaction<StoredVoucher?>((txn) async {
      final held = await txn.query('vouchers', columns: _columns, where: 'key = ?', whereArgs: [key]);
      if (held.isEmpty) {
        final row = {'key': key, 'kind': kind.name, 'hops': hops, 'json': json, 'created_at': DateTime.now().millisecondsSinceEpoch};
        await txn.insert('vouchers', row);
        return _stored(row);
      }
      final claim = held.single['kind'] == VoucherKind.relayed.name &&
          kind != VoucherKind.relayed &&
          held.single['json'] == json;
      if (!claim) return null;
      await txn.update('vouchers', {'kind': kind.name}, where: 'key = ?', whereArgs: [key]);
      // A claimed voucher may have been answered about already: the gateway uploads it as soon as
      // it is carried. Tell it as it stands.
      return _stored({...held.single, 'kind': kind.name});
    });
    if (stored == null) return false;
    _puts.add(stored);
    return true;
  }

  /// Records the relayer's final answer for [voucher], with the settling [tx], [block] and signed
  /// [receipt] (see [held]) if it gave them. The row stays, so the mesh still counts the voucher as
  /// held and does not fetch it again. A voucher recorded as settled stays settled, and keeps the
  /// transaction, block and receipt it has; ones it lacks can still be filled in.
  Future<void> setOutcome(Map<String, dynamic> voucher, Outcome outcome,
      {String? tx, int? block, Map<String, dynamic>? receipt}) async {
    final settled = outcome == Outcome.settled, key = voucherKey(voucher);
    final changed = await _db.rawUpdate(
        "UPDATE vouchers SET outcome = CASE outcome WHEN 'settled' THEN outcome ELSE ? END, tx = COALESCE(tx, ?), "
        'settled_block = COALESCE(settled_block, ?), receipt = COALESCE(receipt, ?) WHERE key = ?',
        [outcome.name, settled ? tx : null, settled ? block : null, settled && receipt != null ? jsonEncode(receipt) : null, key]);
    if (changed == 0) return;
    _outcomes.add((await get(key))!);
  }

  /// Keeps [signed] as the attestation for [account] unless a newer one is already held.
  Future<void> saveAttestation(String account, DateTime asOf, Map<String, dynamic> signed) => _db.rawInsert(
      'INSERT INTO attestations (account, as_of, json) VALUES (?, ?, ?) ON CONFLICT(account) DO UPDATE SET '
      'as_of = excluded.as_of, json = excluded.json WHERE excluded.as_of > attestations.as_of',
      [account, asOf.millisecondsSinceEpoch, jsonEncode(signed)]);

  /// The signed attestation held for [account], or null.
  Future<Map<String, dynamic>?> attestation(String account) async {
    final rows = await _db.query('attestations', columns: ['json'], where: 'account = ?', whereArgs: [account]);
    return rows.isEmpty ? null : jsonDecode(rows.single['json'] as String) as Map<String, dynamic>;
  }

  /// Every voucher held that [signer] signed, in any role: what this phone knows of their spending.
  Future<List<StoredVoucher>> from(String signer) =>
      // A range, which the primary key index can answer; LIKE would read every row. ";" follows ":".
      _select(where: 'key >= ? AND key < ?', whereArgs: ['$signer:', '$signer;']);

  /// The voucher stored under [key], if any.
  Future<StoredVoucher?> get(String key) async => (await _select(where: 'key = ?', whereArgs: [key])).firstOrNull;

  /// Every voucher key held, with the relayer's signed receipt for it where there is one, as the JSON
  /// text it was given in. Two columns only: the mesh asks this for every "have" it hears.
  Future<Map<String, String?>> held() async =>
      {for (final r in await _db.query('vouchers', columns: ['key', 'receipt'])) r['key'] as String: r['receipt'] as String?};

  /// Every voucher key without a final answer. One column: the mesh asks this on every connection.
  Future<List<String>> unanswered() async =>
      [for (final r in await _db.query('vouchers', columns: ['key'], where: 'outcome IS NULL')) r['key'] as String];

  /// Newest first.
  Future<List<StoredVoucher>> all() => _select();

  Future<List<StoredVoucher>> _select({String? where, List<Object?>? whereArgs}) async => [
        for (final r in await _db.query('vouchers', columns: _columns, where: where, whereArgs: whereArgs, orderBy: 'created_at DESC'))
          _stored(r)
      ];

  /// What [_stored] reads; not the receipt, which only the mesh asks for (see [held]).
  static const _columns = ['kind', 'hops', 'json', 'outcome', 'tx', 'settled_block'];

  static StoredVoucher _stored(Map<String, Object?> r) => (
        kind: VoucherKind.values.byName(r['kind'] as String),
        hops: r['hops'] as int,
        voucher: jsonDecode(r['json'] as String) as Map<String, dynamic>,
        outcome: r['outcome'] == null ? null : Outcome.values.byName(r['outcome'] as String),
        tx: r['tx'] as String?,
        settledBlock: r['settled_block'] as int?,
      );
}
