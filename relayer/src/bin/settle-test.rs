//! Gate 1: does a voucher signed now still settle later?
//!   cargo run --bin settle-test -- sign   -> writes voucher.json, signed by an offline key; needs no network
//!   cargo run --bin settle-test -- submit -> (hours later) simulates voucher.json, then settles it with execute_intents
//! sign needs:   OFFLINE_SK (hex ed25519 seed, its implicit account funded in intents.near), RECEIVER, TOKEN, AMOUNT.
//! submit needs: RELAYER_ACCOUNT + RELAYER_KEY (ed25519:... full-access or function-call key of a mainnet
//!               account with NEAR for gas). It pays gas only; the voucher's signature moves the tokens.
//!
//! The slashing, shown on mainnet: the app never signs two vouchers with one sequence number, so a
//! double-spend has to be made by hand.
//!   cargo run --bin settle-test -- cheat  -> signs two payments with one sequence number, uploads both to a
//!               running relayer and waits for the bond contract's answer.
//! cheat needs: OFFLINE_SK (a key of its own, NOT a payer's: the contract bans it for good, and it must have
//!              a bond, `bond_for` with at least 1 NEAR), RELAYER_URL (http://host:8787), RECEIVER and
//!              OTHER_RECEIVER (two accounts), optionally AMOUNT (default 10000: 0.01 USDC, it need not be held).
use chrono::{Duration, Utc};
use ed25519_dalek::SigningKey;
use nearby_relayer::chain::{seed_key, Chain, NearChain};
use nearby_relayer::env;
use nearby_relayer::voucher::{
    implicit_account, iso, make_nonce, sign_voucher, IntentMessage, SignedVoucher, USDC_TOKEN,
};
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
            let saved = json!({ "signedAt": iso(Utc::now()), "v": payment(&key, &receiver, &token, &amount, None) });
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
        Some("cheat") => cheat().await?,
        _ => println!("usage: settle-test sign|submit|cheat"),
    }
    Ok(())
}

/// Two payments by one key to two receivers with the same sequence number, uploaded to a relayer.
async fn cheat() -> Result<(), String> {
    let usage = "set OFFLINE_SK, RELAYER_URL, RECEIVER and OTHER_RECEIVER (see the top of this file)";
    let key = env("OFFLINE_SK").as_deref().and_then(seed_key).ok_or(usage)?;
    let relayer = env("RELAYER_URL").ok_or(usage)?;
    let relayer = relayer.trim_end_matches('/');
    let (receiver, other) = (env("RECEIVER").ok_or(usage)?, env("OTHER_RECEIVER").ok_or(usage)?);
    let amount = env("AMOUNT").unwrap_or_else(|| "10000".into());
    let signer = implicit_account(key.verifying_key().as_bytes());
    let numbered = |to: &str| payment(&key, to, USDC_TOKEN, &amount, Some("seq:1 prev:00"));
    let (a, b) = (numbered(&receiver), numbered(&other));
    println!("{signer} pays {receiver} and {other}, both as payment number 1");
    let client = reqwest::Client::new();
    let answer = json(
        client
            .post(format!("{relayer}/vouchers"))
            .json(&json!({ "vouchers": [a, b] })),
    )
    .await?;
    println!("relayer: {answer}");
    for _ in 0..40 {
        let proofs = json(client.get(format!("{relayer}/equivocations"))).await?;
        let ours = proofs
            .as_array()
            .into_iter()
            .flatten()
            .find(|p| p["b"]["signature"] == json!(b.signature));
        match ours {
            Some(Value::Object(p)) if p.get("tx").is_some_and(Value::is_string) => {
                println!(
                    "slashed: https://nearblocks.io/txns/{}",
                    p["tx"].as_str().unwrap_or_default()
                );
                return Ok(());
            }
            Some(p) if p["refusal"].is_string() => return Err(format!("the bond contract refused: {}", p["refusal"])),
            _ => tokio::time::sleep(std::time::Duration::from_secs(3)).await,
        }
    }
    Err("no answer from the bond contract after two minutes: see the relayer's log".into())
}

/// A payment of `amount` of `token` from `key` to `to`, valid for three days.
fn payment(key: &SigningKey, to: &str, token: &str, amount: &str, memo: Option<&str>) -> SignedVoucher {
    let mut transfer = json!({ "intent": "transfer", "receiver_id": to, "tokens": { token: amount } });
    if let Some(memo) = memo {
        transfer["memo"] = json!(memo);
    }
    let message = IntentMessage {
        signer_id: implicit_account(key.verifying_key().as_bytes()),
        deadline: iso(Utc::now() + Duration::hours(72)),
        intents: vec![transfer],
    };
    sign_voucher(key, &message, &make_nonce())
}

/// The JSON a relayer answers a request with.
async fn json(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let fail = |e: reqwest::Error| e.without_url().to_string();
    request.send().await.map_err(fail)?.json().await.map_err(fail)
}
