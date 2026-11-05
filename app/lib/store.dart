// Vouchers this phone has signed (to relay later) or accepted (pending settlement).
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'voucher/nep413.dart';
import 'voucher/payment.dart';

typedef StoredVoucher = ({bool sent, String amount});

class VoucherStore {
  final Database _db;
  VoucherStore._(this._db);

  static Future<VoucherStore> open([String path = 'nearby.db']) async => VoucherStore._(await openDatabase(path,
      version: 1,
      onCreate: (db, _) => db.execute('CREATE TABLE vouchers '
          '(nonce TEXT PRIMARY KEY, sent INTEGER NOT NULL, json TEXT NOT NULL, created_at INTEGER NOT NULL)')));

  /// Stores a voucher under its nonce. Returns false, storing nothing, if that nonce is already
  /// here: the chain settles each nonce once, so a voucher shown again is the same payment,
  /// not a second one, and the payee must not hand over goods for it twice.
  Future<bool> add(Map<String, dynamic> voucher, {required bool sent}) async {
    try {
      await _db.insert('vouchers', {
        'nonce': nonceId(voucher),
        'sent': sent ? 1 : 0,
        'json': jsonEncode(voucher),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  /// Newest first.
  Future<List<StoredVoucher>> all() async => [
        for (final r in await _db.query('vouchers', orderBy: 'created_at DESC'))
          (sent: r['sent'] == 1, amount: amountOf(jsonDecode(r['json'] as String)))
      ];
}
