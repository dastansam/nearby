// NEP-413 signed transfer intents ("vouchers") for intents.near.
// Must produce byte-identical hashes to relayer/src/voucher.rs.
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

/// intents.near reads a nonce that starts with these bytes as its salted, expiring layout and
/// then checks the salt and a second deadline inside it. Any other 32 bytes are a plain nonce
/// with no such conditions, which is what we sign: nothing to fetch, so it works fully offline.
const versionedNoncePrefix = '5628f6c6';

/// 32 random bytes. Unordered: vouchers settle in any order.
Uint8List makeNonce() {
  final rnd = Random.secure();
  while (true) {
    final nonce = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    if (!hex.encode(nonce).startsWith(versionedNoncePrefix)) return nonce;
  }
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
/// more than one spelling for the same bytes ("/" and "_" decode alike).
String nonceId(Map<String, dynamic> v) => hex.encode(base64.decode(v['payload']['nonce']));

/// Identifies a voucher the way the chain does: it settles one voucher per signer and nonce.
/// Only the signer can produce a voucher under their key, so nobody else can occupy it.
String voucherKey(Map<String, dynamic> v) => '${signerOf(v)}:${nonceId(v)}';

/// The account a voucher spends from: the implicit account of the key that signed it.
String signerOf(Map<String, dynamic> v) => implicitAccount(untag(v['public_key']));

/// Short fingerprint of a voucher, which the payer's next voucher names as its "prev".
String voucherHash(Map<String, dynamic> v) => c.sha256.convert(utf8.encode(v['signature'])).toString().substring(0, 16);

/// A key or signature the way NEAR writes it: "ed25519:<base58>".
String tag(List<int> bytes) => 'ed25519:${base58.encode(Uint8List.fromList(bytes))}';

/// Bytes of an "ed25519:<base58>" key or signature.
Uint8List untag(String tagged) => base58.decode(tagged.replaceFirst('ed25519:', ''));

DateTime voucherDeadline(Map<String, dynamic> v) => DateTime.parse(jsonDecode(v['payload']['message'])['deadline']);

class Transfer {
  final String receiverId;
  final Map<String, String> tokens; // {"nep141:usdc.near": "2500000"}
  final String? memo;
  Transfer(this.receiverId, this.tokens, {this.memo});
  Map<String, dynamic> toJson() =>
      {'intent': 'transfer', 'receiver_id': receiverId, 'tokens': tokens, if (memo != null) 'memo': memo};
}

/// UTC with millisecond precision, like JS toISOString(): the deadline format checked against intents.near.
String _isoMillis(DateTime t) => DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch, isUtc: true).toIso8601String();

/// The exact JSON string that gets signed. Key order matches the relayer (relayer/src/voucher.rs) so both sides
/// hash the same bytes.
String intentMessage(String signerId, List<Transfer> intents, DateTime deadline) => jsonEncode({
      'signer_id': signerId,
      'deadline': _isoMillis(deadline),
      'intents': intents.map((i) => i.toJson()).toList(),
    });

Map<String, dynamic> _envelope(String message, List<int> nonce, List<int> pub, List<int> sig) => {
      'standard': 'nep413',
      'payload': {'message': message, 'nonce': base64.encode(nonce), 'recipient': verifyingContract},
      'public_key': tag(pub),
      'signature': tag(sig),
    };

Future<Map<String, dynamic>> signVoucher(
    SimpleKeyPair key, List<Transfer> intents, DateTime deadline, Uint8List nonce) async {
  final pub = (await key.extractPublicKey()).bytes;
  final message = intentMessage(implicitAccount(pub), intents, deadline);
  final sig = await _ed.sign(nep413Hash(message, nonce, verifyingContract), keyPair: key);
  return _envelope(message, nonce, pub, sig.bytes);
}

/// Offline merchant checks. Returns null if valid, else the reason.
///
/// Dart's decoders accept spellings the contract's do not (URL-safe base64, a misplaced key
/// tag, loose date formats) and ignore fields the contract hashes (callback_url). So beyond a
/// valid signature, the voucher must be exactly what [signVoucher] emits: anything else might
/// verify here and still be unparseable at settlement.
Future<String?> verifyVoucher(Map<String, dynamic> v, {DateTime? now}) async {
  if (v['standard'] != 'nep413') return 'standard';
  final p = v['payload'] as Map<String, dynamic>;
  if (p['recipient'] != verifyingContract) return 'recipient';
  final pub = untag(v['public_key']), sig = untag(v['signature']);
  final nonce = base64.decode(p['nonce']);
  final ok = await _ed.verify(nep413Hash(p['message'], nonce, verifyingContract),
      signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)));
  if (!ok) return 'signature';
  if (jsonEncode(v) != jsonEncode(_envelope(p['message'], nonce, pub, sig))) return 'malformed';
  // A versioned nonce settles only if its salt is still valid and its own deadline has not
  // passed. Neither can be checked offline, so plain nonces only.
  if (nonceId(v).startsWith(versionedNoncePrefix)) return 'nonce';
  final msg = jsonDecode(p['message']) as Map<String, dynamic>;
  if (msg['signer_id'] != implicitAccount(pub)) return 'signer_id';
  final deadline = DateTime.parse(msg['deadline']);
  if (_isoMillis(deadline) != msg['deadline']) return 'deadline';
  if (!deadline.isAfter(now ?? DateTime.now())) return 'expired';
  return null;
}
