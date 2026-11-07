//! Balance attestations: the relayer's signed statement of what an offline account held at a
//! point in time. A payee with no network accepts a voucher only up to this amount, so the
//! relayer key that signs these is pinned in the app.
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

#[derive(Serialize, Debug)]
pub struct SignedAttestation {
    /// The attestation as JSON, signed as these exact bytes.
    pub payload: String,
    /// `ed25519:<base58>`
    pub signature: String,
}

/// Prefixed to the payload before signing, so this key's signatures cannot be passed off as anything else.
pub const ATTESTATION_DOMAIN: &str = "NearBy balance attestation v1\n";

pub fn sign_attestation(key: &SigningKey, a: &Attestation) -> SignedAttestation {
    let payload = serde_json::to_string(a).expect("an attestation is plain JSON");
    let signature = key.sign(format!("{ATTESTATION_DOMAIN}{payload}").as_bytes());
    SignedAttestation {
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
    #[test]
    fn attestations_match_the_shared_cross_language_vector() {
        let vector: Value = serde_json::from_str(include_str!("../../testdata/attestation-vector.json")).unwrap();
        let seed: [u8; 32] = hex::decode(vector["seed_hex"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let key = SigningKey::from_bytes(&seed);
        let attestation: Attestation = serde_json::from_value(vector["attestation"].clone()).unwrap();
        assert_eq!(
            serde_json::to_value(sign_attestation(&key, &attestation)).unwrap(),
            vector["signed"]
        );
        assert_eq!(tag(key.verifying_key().as_bytes()), vector["public_key"]);
    }
}
