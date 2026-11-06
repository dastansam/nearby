//! NEP-413 signed transfer intents ("vouchers") for intents.near.
//! app/lib/voucher/nep413.dart must produce identical bytes; testdata/voucher-vector.json pins both.
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{DateTime, SecondsFormat, Utc};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
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

/// A time in the one form a deadline is signed in: `2026-11-12T10:00:00.000Z`.
pub fn iso(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// 32 random bytes. Unordered: vouchers settle in any order.
pub fn make_nonce() -> [u8; 32] {
    loop {
        let n: [u8; 32] = rand::random();
        if !n.starts_with(&VERSIONED_NONCE_PREFIX) {
            return n;
        }
    }
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

pub fn sign_voucher(key: &SigningKey, message: &impl Serialize, nonce: &[u8; 32]) -> SignedVoucher {
    let message = serde_json::to_string(message).expect("a voucher message is plain JSON");
    let signature = key.sign(&nep413_hash(&message, nonce, VERIFYING_CONTRACT));
    SignedVoucher {
        standard: "nep413".into(),
        payload: Payload {
            message,
            nonce: STANDARD.encode(nonce),
            recipient: VERIFYING_CONTRACT.into(),
        },
        public_key: tag(key.verifying_key().as_bytes()),
        signature: tag(&signature.to_bytes()),
    }
}

/// A validly signed voucher. `expired` is kept apart from the failures: an expired voucher may
/// have settled in time through another gateway, and it still proves a double-spend.
#[derive(Debug)]
pub struct Checked {
    pub message: IntentMessage,
    pub expired: bool,
}

/// Everything about a voucher that can be checked without the chain. The error is the reason.
pub fn verify_voucher(v: &SignedVoucher, now: DateTime<Utc>) -> Result<Checked, &'static str> {
    if v.standard != "nep413" {
        return Err("standard");
    }
    if v.payload.recipient != VERIFYING_CONTRACT {
        return Err("recipient");
    }
    let public_key: [u8; 32] = untag(&v.public_key).ok_or("malformed")?;
    let signature: [u8; 64] = untag(&v.signature).ok_or("malformed")?;
    // Strict standard base64, as the contract reads it: a nonce spelled any other way would not settle.
    let nonce: [u8; 32] = STANDARD
        .decode(&v.payload.nonce)
        .ok()
        .and_then(|n| n.try_into().ok())
        .ok_or("malformed")?;
    let hash = nep413_hash(&v.payload.message, &nonce, &v.payload.recipient);
    // Not verify_strict: the chain has the last word, and turning down here what it would accept
    // tells a payee their payment is worthless when it is not.
    let signed = VerifyingKey::from_bytes(&public_key)
        .is_ok_and(|k| k.verify(&hash, &Signature::from_bytes(&signature)).is_ok());
    if !signed {
        return Err("signature");
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
    // Exactly the UTC millisecond form we sign: the contract rejects a zone-less deadline, and one
    // read loosely here could pass and then fail at settlement, after the relayer has paid gas.
    let deadline = DateTime::parse_from_rfc3339(&message.deadline)
        .map_err(|_| "deadline")?
        .with_timezone(&Utc);
    if iso(deadline) != message.deadline {
        return Err("deadline");
    }
    Ok(Checked {
        message,
        expired: deadline <= now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;
    use serde_json::json;

    fn key() -> SigningKey {
        SigningKey::from_bytes(&rand::random())
    }

    fn message(key: &SigningKey, deadline: &str) -> IntentMessage {
        IntentMessage {
            signer_id: implicit_account(key.verifying_key().as_bytes()),
            deadline: deadline.into(),
            intents: vec![
                json!({ "intent": "transfer", "receiver_id": "merchant.near", "tokens": { "nep141:usdc.near": "2500000" } }),
            ],
        }
    }

    fn in_three_days() -> String {
        iso(Utc::now() + Duration::hours(72))
    }

    fn reason(v: &SignedVoucher) -> Option<&'static str> {
        verify_voucher(v, Utc::now()).err()
    }

    #[test]
    fn signs_and_verifies_a_voucher() {
        let k = key();
        let checked = verify_voucher(
            &sign_voucher(&k, &message(&k, &in_three_days()), &make_nonce()),
            Utc::now(),
        )
        .unwrap();
        assert!(!checked.expired);
    }

    #[test]
    fn rejects_a_tampered_amount() {
        let k = key();
        let mut v = sign_voucher(&k, &message(&k, &in_three_days()), &make_nonce());
        v.payload.message = v.payload.message.replace("2500000", "9500000");
        assert_eq!(reason(&v), Some("signature"));
    }

    #[test]
    fn an_expired_voucher_is_still_validly_signed_and_says_so() {
        let k = key();
        let v = sign_voucher(&k, &message(&k, "2020-01-01T00:00:00.000Z"), &make_nonce());
        assert!(verify_voucher(&v, Utc::now()).unwrap().expired);
    }

    // The contract rejects these at settlement, after the relayer has paid gas.
    #[test]
    fn rejects_a_deadline_that_is_not_the_utc_form_we_sign() {
        let k = key();
        for deadline in [
            "garbage",
            "2099-01-01T00:00:00",
            "20990101T000000Z",
            "2099-01-01T00:00:00Z",
            "2099-01-01T02:00:00.000+02:00",
        ] {
            assert_eq!(
                reason(&sign_voucher(&k, &message(&k, deadline), &make_nonce())),
                Some("deadline"),
                "{deadline}"
            );
        }
    }

    // Mainnet rejects "5628f6c6 + version + salt + deadline" nonces with "invalid salt" or "deadline is
    // greater than nonce". A payer could craft one that verifies offline and never settles.
    #[test]
    fn rejects_a_versioned_nonce_whose_salt_and_expiry_cannot_be_checked_offline() {
        let k = key();
        let mut crafted = [7u8; 32];
        crafted[..5].copy_from_slice(&[0x56, 0x28, 0xf6, 0xc6, 0]);
        assert_eq!(
            reason(&sign_voucher(&k, &message(&k, &in_three_days()), &crafted)),
            Some("nonce")
        );
    }

    // The contract takes the standard base64 alphabet only; "/" spelled "_" would pass a loose decoder.
    #[test]
    fn rejects_a_nonce_respelled_in_url_safe_base64() {
        let k = key();
        let mut v = sign_voucher(&k, &message(&k, &in_three_days()), &[0xff; 32]);
        v.payload.nonce = v.payload.nonce.replace('/', "_");
        assert_eq!(reason(&v), Some("malformed"));
    }

    #[test]
    fn rejects_a_voucher_signed_for_someone_elses_account() {
        let k = key();
        let v = sign_voucher(&k, &message(&key(), &in_three_days()), &make_nonce());
        assert_eq!(reason(&v), Some("signer_id"));
    }

    #[test]
    fn parallel_vouchers_get_distinct_nonces() {
        assert_ne!(make_nonce(), make_nonce());
    }

    // The phone signs with app/lib/voucher/nep413.dart, which is pinned to the same vector.
    // If this output changes, the two signers have diverged and phone-signed vouchers stop settling.
    #[test]
    fn matches_the_shared_cross_language_vector() {
        let vector: Value = serde_json::from_str(include_str!("../../testdata/voucher-vector.json")).unwrap();
        let bytes =
            |name: &str| -> [u8; 32] { hex::decode(vector[name].as_str().unwrap()).unwrap().try_into().unwrap() };
        let v = sign_voucher(
            &SigningKey::from_bytes(&bytes("seed_hex")),
            &vector["message"],
            &bytes("nonce_hex"),
        );
        assert_eq!(serde_json::to_value(&v).unwrap(), vector["voucher"]);
    }
}
