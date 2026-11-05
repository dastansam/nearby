// The offline spending key and the cached intents.near nonce salt, kept in the platform keystore.
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'voucher/nep413.dart';

const _rpc = 'https://rpc.mainnet.near.org';
// resetOnError defaults to true, which wipes the keystore on a decrypt error; load() would then
// see no seed and mint a new key, orphaning the funded account. Fail instead.
const _storage = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));

class Wallet {
  final SimpleKeyPair key;

  /// The key's NEAR implicit account. Fund it inside intents.near to set the offline budget.
  final String accountId;

  /// Hex salt every voucher nonce must start with. Null until the first online refresh.
  String? salt;

  Wallet._(this.key, this.accountId, this.salt);

  static Future<Wallet> load() async {
    var seedHex = await _storage.read(key: 'offline_seed');
    if (seedHex == null) {
      seedHex = hex.encode(await (await Ed25519().newKeyPair()).extractPrivateKeyBytes());
      await _storage.write(key: 'offline_seed', value: seedHex);
    }
    final key = await Ed25519().newKeyPairFromSeed(hex.decode(seedHex));
    final pub = await key.extractPublicKey();
    return Wallet._(key, implicitAccount(pub.bytes), await _storage.read(key: 'salt'));
  }

  /// Online only: fetch intents.near's current salt and cache it for offline signing.
  Future<void> refreshSalt() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse(_rpc));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'query',
        'params': {
          'request_type': 'call_function',
          'finality': 'final',
          'account_id': verifyingContract,
          'method_name': 'current_salt',
          'args_base64': base64.encode(utf8.encode('{}')),
        },
      }));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      final fetched = jsonDecode(utf8.decode((body['result']['result'] as List).cast<int>())) as String;
      if (hex.decode(fetched).length != 4) throw const FormatException('salt must be 4 bytes');
      await _storage.write(key: 'salt', value: fetched);
      salt = fetched;
    } finally {
      client.close(force: true);
    }
  }
}
