//! Gate 1: does a voucher signed now still settle later?
//!   cargo run --bin settle-test -- sign   -> writes voucher.json, signed by an offline key; needs no network
//!   cargo run --bin settle-test -- submit -> (hours later) simulates voucher.json, then settles it with execute_intents
//! sign needs:   OFFLINE_SK (hex ed25519 seed, its implicit account funded in intents.near), RECEIVER, TOKEN, AMOUNT.
//! submit needs: RELAYER_ACCOUNT + RELAYER_KEY (ed25519:... full-access or function-call key of a mainnet
//!               account with NEAR for gas). It pays gas only; the voucher's signature moves the tokens.
use chrono::{Duration, Utc};
use nearby_relayer::chain::{seed_key, Chain, NearChain};
use nearby_relayer::env;
use nearby_relayer::voucher::{implicit_account, iso, make_nonce, sign_voucher, IntentMessage, SignedVoucher};
use serde_json::{json, Value};

#[tokio::main]
async fn main() -> Result<(), String> {
    match std::env::args().nth(1).as_deref() {
        Some("sign") => {
            // A missing value would sign a voucher that only fails at submit, a day later.
            let usage = "set OFFLINE_SK (64 hex characters), RECEIVER, TOKEN and AMOUNT";
            let key = env("OFFLINE_SK").as_deref().and_then(seed_key).ok_or(usage)?;
            let (receiver, token, amount) = (
                env("RECEIVER").ok_or(usage)?,
                env("TOKEN").ok_or(usage)?,
                env("AMOUNT").ok_or(usage)?,
            );
            let signer = implicit_account(key.verifying_key().as_bytes());
            let message = IntentMessage {
                signer_id: signer.clone(),
                deadline: iso(Utc::now() + Duration::hours(72)),
                intents: vec![json!({ "intent": "transfer", "receiver_id": receiver, "tokens": { token: amount } })],
            };
            let saved = json!({ "signedAt": iso(Utc::now()), "v": sign_voucher(&key, &message, &make_nonce()) });
            std::fs::write("voucher.json", format!("{saved:#}")).map_err(|e| e.to_string())?;
            println!("signed by {signer}");
        }
        Some("submit") => {
            let saved: Value =
                serde_json::from_str(&std::fs::read_to_string("voucher.json").map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            let v: SignedVoucher = serde_json::from_value(saved["v"].clone()).map_err(|e| e.to_string())?;
            println!("signed at {}", saved["signedAt"]);
            // The same code path the relayer settles with.
            let chain = NearChain::from_env()?;
            // simulate_intents is a view: it fails on a bad signature, nonce, deadline or balance before we spend gas.
            chain
                .simulate(&v)
                .await
                .map_err(|e| format!("simulation: {}", e.reason()))?;
            println!("simulated: ok");
            let tx = chain
                .execute(&v)
                .await
                .map_err(|e| format!("settlement: {}", e.reason()))?;
            println!("settled: https://nearblocks.io/txns/{tx}");
        }
        _ => println!("usage: settle-test sign|submit"),
    }
    Ok(())
}
