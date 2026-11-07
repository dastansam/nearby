//! NEP-413 signed transfer intents ("vouchers") for intents.near: the shapes and the hash, and
//! behind the `sign` feature a signer. Checking needs no clock, randomness or key, so the bond
//! contract can use it too.
//! app/lib/voucher/nep413.dart must produce identical bytes; testdata/voucher-vector.json pins both.
use std::collections::BTreeMap;

use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub const VERIFYING_CONTRACT: &str = "intents.near";
/// USDC on NEAR as held inside intents.near: the one token the app pays in.
pub const USDC_TOKEN: &str = "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1";
const NEP413_TAG: u32 = (1 << 31) + 413;

/// intents.near reads a nonce that starts with these bytes as its salted, expiring layout and then
/// checks the salt and a second deadline inside it. Any other 32 bytes are a plain nonce with no
/// such conditions, which is what we sign: nothing to fetch, so it works fully offline.
pub const VERSIONED_NONCE_PREFIX: [u8; 4] = [0x56, 0x28, 0xf6, 0xc6];

/// What a voucher's signature covers, as JSON text. Intents stay untyped: the relayer has to
/// recognise and turn down kinds it does not settle.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct IntentMessage {
    pub signer_id: String,
    /// ISO 8601, UTC, milliseconds.
    pub deadline: String,
    pub intents: Vec<Value>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Payload {
    pub message: String,
    /// Base64 of 32 bytes.
    pub nonce: String,
    pub recipient: String,
}

/// Exactly the fields intents.near hashes and checks, in the order the app writes them.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SignedVoucher {
    pub standard: String,
    pub payload: Payload,
    /// `ed25519:<base58>`
    pub public_key: String,
    /// `ed25519:<base58>`
    pub signature: String,
}

/// The one intent a NearBy payment carries.
#[derive(Deserialize, Clone, Debug, PartialEq)]
pub struct Transfer {
    pub receiver_id: String,
    /// Token id -> amount, as decimal text.
    pub tokens: BTreeMap<String, String>,
    #[serde(default)]
    pub memo: String,
}

impl Transfer {
    /// The payer's sequence number, from a memo such as "req:9f2c seq:17 prev:00".
    pub fn sequence(&self) -> Option<&str> {
        self.memo
            .split(' ')
            .find_map(|entry| entry.strip_prefix("seq:"))
            .filter(|seq| !seq.is_empty())
    }
}

/// The transfer a message consists of, if it is exactly one.
pub fn transfer(message: &IntentMessage) -> Option<Transfer> {
    let [intent] = message.intents.as_slice() else {
        return None;
    };
    if intent["intent"] != "transfer" {
        return None;
    }
    Transfer::deserialize(intent).ok()
}

/// A key or signature the way NEAR writes it.
pub fn tag(bytes: &[u8]) -> String {
    format!("ed25519:{}", bs58::encode(bytes).into_string())
}

/// The bytes of an `ed25519:<base58>` key or signature, if it is one of the right length.
pub fn untag<const N: usize>(tagged: &str) -> Option<[u8; N]> {
    let bytes = bs58::decode(tagged.strip_prefix("ed25519:").unwrap_or(tagged))
        .into_vec()
        .ok()?;
    bytes.try_into().ok()
}

/// The 32 bytes of a nonce, read as strictly as intents.near reads it: standard base64 only, since
/// a nonce spelled any other way would not settle.
pub fn decode_nonce(nonce: &str) -> Option<[u8; 32]> {
    STANDARD.decode(nonce).ok()?.try_into().ok()
}

pub fn encode_nonce(nonce: &[u8; 32]) -> String {
    STANDARD.encode(nonce)
}

/// sha256(borsh(tag) || borsh({message, nonce[32], recipient, callback_url: None}))
pub fn nep413_hash(message: &str, nonce: &[u8; 32], recipient: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    let string = |h: &mut Sha256, s: &str| {
        h.update((s.len() as u32).to_le_bytes());
        h.update(s);
    };
    h.update(NEP413_TAG.to_le_bytes());
    string(&mut h, message);
    h.update(nonce);
    string(&mut h, recipient);
    h.update([0u8]);
    h.finalize().into()
}

/// Implicit account id: the hex of the ed25519 public key.
pub fn implicit_account(public_key: &[u8; 32]) -> String {
    hex::encode(public_key)
}

/// 32 random bytes. Unordered: vouchers settle in any order.
#[cfg(feature = "sign")]
pub fn make_nonce() -> [u8; 32] {
    loop {
        let n: [u8; 32] = rand::random();
        if !n.starts_with(&VERSIONED_NONCE_PREFIX) {
            return n;
        }
    }
}

#[cfg(feature = "sign")]
pub fn sign_voucher(key: &ed25519_dalek::SigningKey, message: &impl Serialize, nonce: &[u8; 32]) -> SignedVoucher {
    use ed25519_dalek::Signer;
    let message = serde_json::to_string(message).expect("a voucher message is plain JSON");
    let signature = key.sign(&nep413_hash(&message, nonce, VERIFYING_CONTRACT));
    SignedVoucher {
        standard: "nep413".into(),
        payload: Payload {
            message,
            nonce: encode_nonce(nonce),
            recipient: VERIFYING_CONTRACT.into(),
        },
        public_key: tag(key.verifying_key().as_bytes()),
        signature: tag(&signature.to_bytes()),
    }
}

/// The parts of a voucher that a signature check needs, and everything about its spelling that
/// can be wrong. Does not check the signature: the relayer and the contract each do that their
/// own way. The error is the reason.
pub struct Parsed {
    pub public_key: [u8; 32],
    pub signature: [u8; 64],
    pub hash: [u8; 32],
    pub message: IntentMessage,
}

pub fn parse_voucher(v: &SignedVoucher) -> Result<Parsed, &'static str> {
    if v.standard != "nep413" {
        return Err("standard");
    }
    if v.payload.recipient != VERIFYING_CONTRACT {
        return Err("recipient");
    }
    let public_key: [u8; 32] = untag(&v.public_key).ok_or("malformed")?;
    let signature: [u8; 64] = untag(&v.signature).ok_or("malformed")?;
    let nonce = decode_nonce(&v.payload.nonce).ok_or("malformed")?;
    // One spelling only, as the app requires too. The relayer tells vouchers apart by their signature
    // text: a copy with the "ed25519:" left off would pass for a second voucher, and a double-spend.
    if v.public_key != tag(&public_key) || v.signature != tag(&signature) {
        return Err("malformed");
    }
    // A versioned nonce settles only if its salt is still valid and its own deadline has not passed.
    // Neither can be checked offline, so plain nonces only.
    if nonce.starts_with(&VERSIONED_NONCE_PREFIX) {
        return Err("nonce");
    }
    let message: IntentMessage = serde_json::from_str(&v.payload.message).map_err(|_| "malformed")?;
    if message.signer_id != implicit_account(&public_key) {
        return Err("signer_id");
    }
    Ok(Parsed {
        hash: nep413_hash(&v.payload.message, &nonce, &v.payload.recipient),
        public_key,
        signature,
        message,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn message(memo: &str) -> IntentMessage {
        IntentMessage {
            signer_id: "a".repeat(64),
            deadline: "2026-11-12T10:00:00.000Z".into(),
            intents: vec![json!({
                "intent": "transfer", "receiver_id": "cafe.near",
                "tokens": { USDC_TOKEN: "2500000" }, "memo": memo,
            })],
        }
    }

    #[test]
    fn reads_the_sequence_number_out_of_the_memo() {
        let t = transfer(&message("req:9f2c seq:17 prev:00")).unwrap();
        assert_eq!(t.receiver_id, "cafe.near");
        assert_eq!(t.sequence(), Some("17"));
        assert_eq!(transfer(&message("req:9f2c")).unwrap().sequence(), None);
        assert_eq!(transfer(&message("seq:")).unwrap().sequence(), None);
    }

    // A proof of double-spending pays the bond to a voucher's receiver; a message with two intents
    // or a non-transfer has no single receiver, so it is not a NearBy payment.
    #[test]
    fn only_a_lone_transfer_is_a_payment() {
        let mut two = message("seq:1");
        two.intents.push(two.intents[0].clone());
        assert!(transfer(&two).is_none());
        let mut swap = message("seq:1");
        swap.intents[0]["intent"] = json!("token_diff");
        assert!(transfer(&swap).is_none());
        let mut no_memo = message("seq:1");
        no_memo.intents[0].as_object_mut().unwrap().remove("memo");
        assert_eq!(transfer(&no_memo).unwrap().sequence(), None);
    }
}
