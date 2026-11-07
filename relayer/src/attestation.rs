//! What the relayer signs for phones that are offline: balance attestations (what an offline
//! account held at a point in time; a payee with no network accepts a voucher only up to this
//! amount) and settlement receipts (that a voucher is on chain, for the phones still carrying
//! it). The relayer key that signs these is pinned in the app.
use crate::voucher::tag;
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};

/// Field order is the order signed: app/lib/voucher/attestation.dart verifies these exact bytes.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Attestation {
    pub account: String,
    pub token: String,
    /// Token base units inside intents.near.
    pub balance: String,
    pub bond: String,
    /// ISO 8601; the app treats the attestation as valid for 24 h from here.
    pub as_of: String,
    /// Height of the block the balance was read at. A payment settled by this height is already in
    /// the balance; a later one is not. Heights, not clocks: the reading and the settlement can
    /// come from RPC nodes that are a block apart.
    pub block: u64,
}

/// The relayer's word that a voucher settled, for the phones that were offline when it did and
/// are still carrying it, or still counting it against the payer.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Receipt {
    /// The voucher's signature, `ed25519:<base58>`: how phones and relayer alike tell vouchers apart.
    pub voucher: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx: Option<String>,
    /// A height by which it had settled: an attestation read at that height or later already
    /// reflects the payment.
    pub block: u64,
}

/// A statement as JSON and the relayer key's signature over it.
#[derive(Serialize, Debug)]
pub struct Signed {
    /// Signed as these exact bytes.
    pub payload: String,
    /// `ed25519:<base58>`
    pub signature: String,
}

/// Prefixed to the payload before signing, so this key's signatures cannot be passed off as anything else.
pub const ATTESTATION_DOMAIN: &str = "NearBy balance attestation v1\n";
pub const RECEIPT_DOMAIN: &str = "NearBy settlement receipt v1\n";

pub fn sign_attestation(key: &SigningKey, a: &Attestation) -> Signed {
    sign(key, ATTESTATION_DOMAIN, a)
}

pub fn sign_receipt(key: &SigningKey, r: &Receipt) -> Signed {
    sign(key, RECEIPT_DOMAIN, r)
}

fn sign(key: &SigningKey, domain: &str, statement: &impl Serialize) -> Signed {
    let payload = serde_json::to_string(statement).expect("a statement is plain JSON");
    let signature = key.sign(format!("{domain}{payload}").as_bytes());
    Signed {
        payload,
        signature: tag(&signature.to_bytes()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    // The app verifies attestations with app/lib/voucher/attestation.dart, pinned to the same vector.
    // If this output changes, phones stop trusting what the relayer signs.
    fn key_from(vector: &Value) -> SigningKey {
        let seed: [u8; 32] = hex::decode(vector["seed_hex"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        SigningKey::from_bytes(&seed)
    }

    #[test]
    fn attestations_match_the_shared_cross_language_vector() {
        let vector: Value = serde_json::from_str(include_str!("../../testdata/attestation-vector.json")).unwrap();
        let key = key_from(&vector);
        let attestation: Attestation = serde_json::from_value(vector["attestation"].clone()).unwrap();
        assert_eq!(
            serde_json::to_value(sign_attestation(&key, &attestation)).unwrap(),
            vector["signed"]
        );
        assert_eq!(tag(key.verifying_key().as_bytes()), vector["public_key"]);
    }

    // The app verifies receipts with the same key and its own domain string; the vector pins both.
    #[test]
    fn receipts_match_the_shared_cross_language_vector() {
        let vector: Value = serde_json::from_str(include_str!("../../testdata/receipt-vector.json")).unwrap();
        let receipt: Receipt = serde_json::from_value(vector["receipt"].clone()).unwrap();
        assert_eq!(
            serde_json::to_value(sign_receipt(&key_from(&vector), &receipt)).unwrap(),
            vector["signed"]
        );
    }
}
