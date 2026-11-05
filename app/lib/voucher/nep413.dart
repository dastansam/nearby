// NEP-413 signed transfer intents ("vouchers") for intents.near.
// Must produce byte-identical hashes to relayer/src/voucher.ts.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

const verifyingContract = 'intents.near';
const _nep413Tag = 2147484061; // 2^31 + 413

final _ed = Ed25519();

/// 32-byte nonce = 4-byte contract salt + 28 random bytes. Unordered: vouchers settle in any order.
Uint8List makeNonce(String saltHex) {
  final salt = hex.decode(saltHex);
  if (salt.length != 4) throw ArgumentError('salt must be 4 bytes');
  final rnd = Random.secure();
  return Uint8List.fromList([...salt, ...List.generate(28, (_) => rnd.nextInt(256))]);
}

Uint8List _u32(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n, Endian.little);
Uint8List _str(String s) {
  final b = utf8.encode(s);
  return Uint8List.fromList([..._u32(b.length), ...b]);
}

/// sha256(borsh(tag) || borsh({message, nonce[32], recipient, callback_url: None}))
Uint8List nep413Hash(String message, Uint8List nonce, String recipient) {
  if (nonce.length != 32) throw ArgumentError('nonce must be 32 bytes');
  final bytes = [..._u32(_nep413Tag), ..._str(message), ...nonce, ..._str(recipient), 0];
  return Uint8List.fromList(c.sha256.convert(bytes).bytes);
}

String implicitAccount(List<int> pub) => hex.encode(pub);

/// Canonical id of a voucher's nonce: hex of its bytes, not the base64 string, which has
/// more than one spelling for the same bytes ("/" and "_" decode alike). The storage key.
String nonceId(Map<String, dynamic> v) => hex.encode(base64.decode(v['payload']['nonce']));

class Transfer {
  final String receiverId;
  final Map<String, String> tokens; // {"nep141:usdc.near": "2500000"}
  final String? memo;
  Transfer(this.receiverId, this.tokens, {this.memo});
  Map<String, dynamic> toJson() =>
      {'intent': 'transfer', 'receiver_id': receiverId, 'tokens': tokens, if (memo != null) 'memo': memo};
}

Future<Map<String, dynamic>> signVoucher(
    SimpleKeyPair key, List<Transfer> intents, DateTime deadline, Uint8List nonce) async {
  final pub = (await key.extractPublicKey()).bytes;
  // Key order matches the TS reference so both sides hash the same string.
  final message = jsonEncode({
    'signer_id': implicitAccount(pub),
    // Millisecond precision like JS toISOString(), the format checked against intents.near.
    'deadline': DateTime.fromMillisecondsSinceEpoch(deadline.millisecondsSinceEpoch, isUtc: true).toIso8601String(),
    'intents': intents.map((i) => i.toJson()).toList(),
  });
  final sig = await _ed.sign(nep413Hash(message, nonce, verifyingContract), keyPair: key);
  return {
    'standard': 'nep413',
    'payload': {'message': message, 'nonce': base64.encode(nonce), 'recipient': verifyingContract},
    'public_key': 'ed25519:${base58.encode(Uint8List.fromList(pub))}',
    'signature': 'ed25519:${base58.encode(Uint8List.fromList(sig.bytes))}',
  };
}

/// Offline merchant checks. Returns null if valid, else the reason.
Future<String?> verifyVoucher(Map<String, dynamic> v, {DateTime? now}) async {
  if (v['standard'] != 'nep413') return 'standard';
  final p = v['payload'] as Map<String, dynamic>;
  if (p['recipient'] != verifyingContract) return 'recipient';
  final pub = base58.decode((v['public_key'] as String).replaceFirst('ed25519:', ''));
  final sig = base58.decode((v['signature'] as String).replaceFirst('ed25519:', ''));
  final hash = nep413Hash(p['message'], base64.decode(p['nonce']), p['recipient']);
  final ok = await _ed.verify(hash,
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)));
  if (!ok) return 'signature';
  final msg = jsonDecode(p['message']) as Map<String, dynamic>;
  if (msg['signer_id'] != implicitAccount(pub)) return 'signer_id';
  final deadline = DateTime.parse(msg['deadline']);
  // Without a zone Dart reads local time, but the contract's RFC 3339 parser rejects it outright.
  if (!deadline.isUtc) return 'deadline';
  if (!deadline.isAfter(now ?? DateTime.now())) return 'expired';
  return null;
}
