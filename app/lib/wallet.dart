// The offline spending key, kept in the platform keystore.
import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'voucher/nep413.dart';

// resetOnError defaults to true, which wipes the keystore on a decrypt error; load() would then
// see no seed and mint a new key, orphaning the funded account. Fail instead.
const _storage = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));

class Wallet {
  final SimpleKeyPair key;

  /// The key's NEAR implicit account. Fund it inside intents.near to set the offline budget.
  final String accountId;

  Wallet._(this.key, this.accountId);

  static Future<Wallet> load() async {
    var seedHex = await _storage.read(key: 'offline_seed');
    if (seedHex == null) {
      seedHex = hex.encode(await (await Ed25519().newKeyPair()).extractPrivateKeyBytes());
      await _storage.write(key: 'offline_seed', value: seedHex);
    }
    final key = await Ed25519().newKeyPairFromSeed(hex.decode(seedHex));
    final pub = await key.extractPublicKey();
    return Wallet._(key, implicitAccount(pub.bytes));
  }
}
