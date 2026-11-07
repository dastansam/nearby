//! Verifying vouchers. The shapes, the hash and the signer live in the `voucher` crate, which the
//! bond contract shares; this adds the checks that need a clock and a full signature verifier.
use chrono::{DateTime, SecondsFormat, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
pub use voucher::*;

/// A time in the one form a deadline is signed in: `2026-11-12T10:00:00.000Z`.
pub fn iso(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Millis, true)
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
    let Parsed {
        public_key,
        signature,
        hash,
        message,
    } = parse_voucher(v)?;
    // Not verify_strict: the chain has the last word, and turning down here what it would accept
    // tells a payee their payment is worthless when it is not.
    let signed = VerifyingKey::from_bytes(&public_key)
        .is_ok_and(|k| k.verify(&hash, &Signature::from_bytes(&signature)).is_ok());
    if !signed {
        return Err("signature");
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
    use ed25519_dalek::SigningKey;
    use serde_json::{json, Value};

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

    // Anyone carrying a voucher could otherwise re-upload it respelled, and the relayer would
    // publish the two spellings as proof that an honest payer double-spent.
    #[test]
    fn rejects_a_key_or_signature_written_without_its_prefix() {
        let k = key();
        let signed = sign_voucher(&k, &message(&k, &in_three_days()), &make_nonce());
        let (mut bare_signature, mut bare_key) = (signed.clone(), signed.clone());
        bare_signature.signature = signed.signature.replace("ed25519:", "");
        bare_key.public_key = signed.public_key.replace("ed25519:", "");
        assert_eq!(reason(&signed), None);
        assert_eq!(reason(&bare_signature), Some("malformed"));
        assert_eq!(reason(&bare_key), Some("malformed"));
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
