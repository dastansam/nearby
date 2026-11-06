//! What the relayer needs from NEAR. A trait, so the settlement rules can be tested without a network.
use crate::env;
use crate::voucher::{tag, untag, SignedVoucher, VERIFYING_CONTRACT};
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::LazyLock;
use std::time::Duration;

/// An answer from the chain together with the height of the block it was read at.
#[derive(Debug, Clone, PartialEq)]
pub struct At<T> {
    pub value: T,
    pub block: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ChainError {
    /// The contract itself refused; the text is its reason ("insufficient balance or overflow",
    /// "deadline has expired"). A refusal is an answer about the voucher.
    Refused(String),
    /// The chain could not be reached, or answered something else. It says nothing about the
    /// voucher: try again.
    Unknown(String),
}

impl ChainError {
    pub fn reason(&self) -> &str {
        match self {
            Self::Refused(reason) | Self::Unknown(reason) => reason,
        }
    }

    /// For calls that do not judge a voucher: if the contract panics there, that says something
    /// about the contract, and nothing about any voucher.
    fn not_a_refusal(self) -> Self {
        Self::Unknown(self.reason().to_owned())
    }
}

pub trait Chain: Send + Sync + 'static {
    /// Base units of `token` the account holds inside intents.near.
    fn balance_of(&self, account: &str, token: &str) -> impl Future<Output = Result<At<String>, ChainError>> + Send;
    /// Whether a voucher with this signer and nonce has settled (or the nonce was otherwise spent).
    /// The contract spends the nonce and moves the tokens in one step, so a balance read at that
    /// height or later already includes the payment, and one read earlier does not.
    fn is_nonce_used(
        &self,
        account: &str,
        nonce_base64: &str,
    ) -> impl Future<Output = Result<At<bool>, ChainError>> + Send;
    /// A free dry run. Refused if the voucher would not settle right now.
    fn simulate(&self, v: &SignedVoucher) -> impl Future<Output = Result<(), ChainError>> + Send;
    /// Settles the voucher, paying gas, and returns the transaction hash. Refused if the contract turns it down.
    fn execute(&self, v: &SignedVoucher) -> impl Future<Output = Result<String, ChainError>> + Send;
}

/// The most gas one transaction may use; execute_intents gets all of it and is charged only what it burns.
const GAS: u64 = 300_000_000_000_000;

/// intents.near on mainnet, over JSON-RPC.
pub struct NearChain {
    http: reqwest::Client,
    rpc: String,
    account: String,
    key: SigningKey,
    /// The last access-key nonce this process used. The node answering a view can be a block
    /// behind the one that ran our previous transaction, and would hand the same nonce out again.
    last_nonce: AtomicU64,
}

impl NearChain {
    /// `account` pays the gas with `key`, one of its access keys.
    pub fn new(account: String, key: SigningKey, rpc: Option<String>) -> Self {
        Self {
            // send_tx answers only once the transaction has run, which takes a few blocks.
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()
                .expect("an HTTP client"),
            rpc: rpc.unwrap_or_else(|| "https://rpc.mainnet.near.org".into()),
            account,
            key,
            last_nonce: AtomicU64::new(0),
        }
    }

    /// The relayer account from RELAYER_ACCOUNT and RELAYER_KEY, on NEAR_RPC if that is set.
    pub fn from_env() -> Result<Self, &'static str> {
        let usage = "set RELAYER_ACCOUNT and RELAYER_KEY (ed25519:...)";
        let key = env("RELAYER_KEY").as_deref().and_then(secret_key).ok_or(usage)?;
        Ok(Self::new(env("RELAYER_ACCOUNT").ok_or(usage)?, key, env("NEAR_RPC")))
    }

    async fn call(&self, method: &str, params: Value) -> Result<Value, ChainError> {
        let request = json!({ "jsonrpc": "2.0", "id": "nearby", "method": method, "params": params });
        let sent = async {
            self.http
                .post(&self.rpc)
                .json(&request)
                .send()
                .await?
                .json::<Value>()
                .await
        };
        // Without the URL: it can hold the RPC provider's API key, and this text is sent on to phones.
        let mut response = sent
            .await
            .map_err(|e| ChainError::Unknown(e.without_url().to_string()))?;
        match response.get_mut("result") {
            // Some nodes report a failed view inside the result rather than as an RPC error.
            Some(result) if result.get("error").is_none() => Ok(result.take()),
            _ => Err(classify(&response)),
        }
    }

    /// A view call on intents.near, with the height it ran at.
    async fn view(&self, method: &str, args: Value) -> Result<At<Value>, ChainError> {
        let query = json!({
            "request_type": "call_function",
            "finality": "optimistic",
            "account_id": VERIFYING_CONTRACT,
            "method_name": method,
            "args_base64": STANDARD.encode(args.to_string()),
        });
        let result = self.call("query", query).await?;
        let returned = Vec::<u8>::deserialize(&result["result"]).ok();
        let value = returned.and_then(|bytes| serde_json::from_slice(&bytes).ok());
        match (value, result["block_height"].as_u64()) {
            (Some(value), Some(block)) => Ok(At { value, block }),
            _ => Err(ChainError::Unknown(format!("unexpected answer to {method}: {result}"))),
        }
    }
}

impl Chain for NearChain {
    async fn balance_of(&self, account: &str, token: &str) -> Result<At<String>, ChainError> {
        let At { value, block } = self
            .view("mt_balance_of", json!({ "account_id": account, "token_id": token }))
            .await
            .map_err(ChainError::not_a_refusal)?;
        let balance = value
            .as_str()
            .ok_or_else(|| ChainError::Unknown(format!("balance is not a string: {value}")))?;
        Ok(At {
            value: balance.to_owned(),
            block,
        })
    }

    async fn is_nonce_used(&self, account: &str, nonce_base64: &str) -> Result<At<bool>, ChainError> {
        let At { value, block } = self
            .view("is_nonce_used", json!({ "account_id": account, "nonce": nonce_base64 }))
            .await
            .map_err(ChainError::not_a_refusal)?;
        let used = value
            .as_bool()
            .ok_or_else(|| ChainError::Unknown(format!("is_nonce_used is not a boolean: {value}")))?;
        Ok(At { value: used, block })
    }

    async fn simulate(&self, v: &SignedVoucher) -> Result<(), ChainError> {
        self.view("simulate_intents", json!({ "signed": [v] }))
            .await
            .map(|_| ())
    }

    async fn execute(&self, v: &SignedVoucher) -> Result<String, ChainError> {
        let unexpected = |what: &str, got: &Value| ChainError::Unknown(format!("unexpected {what}: {got}"));
        let public_key = self.key.verifying_key().to_bytes();
        let access = json!({ "request_type": "view_access_key", "finality": "optimistic", "account_id": self.account, "public_key": tag(&public_key) });
        // A final block: a transaction that names a block which is later dropped is invalid.
        let (access, block) = tokio::try_join!(
            self.call("query", access),
            self.call("block", json!({ "finality": "final" }))
        )
        .map_err(ChainError::not_a_refusal)?;
        let seen = access["nonce"]
            .as_u64()
            .ok_or_else(|| unexpected("access key", &access))?;
        let next = |last: u64| Some(last.max(seen) + 1);
        let nonce = self
            .last_nonce
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, next)
            .map(|last| last.max(seen) + 1)
            .expect("always Some");
        let block_hash: [u8; 32] = block["header"]["hash"]
            .as_str()
            .and_then(untag)
            .ok_or_else(|| unexpected("block", &block))?;

        let args = json!({ "signed": [v] }).to_string();
        let transaction = execute_intents(&self.account, &public_key, nonce, &block_hash, args.as_bytes());
        let sent = json!({ "signed_tx_base64": STANDARD.encode(sign(&self.key, transaction)), "wait_until": "EXECUTED_OPTIMISTIC" });
        let outcome = self.call("send_tx", sent).await?;
        if let Some(failure) = outcome["status"].get("Failure") {
            return Err(failed(failure));
        }
        // Only a transaction seen to succeed is reported as settled. One still in flight is found
        // through its nonce when the voucher is uploaded again.
        match (
            outcome["status"].get("SuccessValue"),
            outcome["transaction"]["hash"].as_str(),
        ) {
            (Some(_), Some(hash)) => Ok(hash.to_owned()),
            _ => Err(unexpected("transaction outcome", &outcome)),
        }
    }
}

/// A transaction that ran and failed. Whatever the reason, that is the chain's answer about this
/// voucher: called anything else, every phone would send it again and each try would cost gas.
fn failed(failure: &Value) -> ChainError {
    ChainError::Refused(classify(failure).reason().to_owned())
}

/// An RPC error or failed execution, as a refusal when it is the contract panicking.
fn classify(error: &Value) -> ChainError {
    static DEBUG_FORM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"panic_msg: "((?:[^"\\]|\\.)*)""#).unwrap());
    // Nodes spell a panic three ways: a "panic_msg" field, Rust debug text holding one, or a sentence.
    fn panic_in(v: &Value) -> Option<String> {
        match v {
            Value::String(s) => match DEBUG_FORM.captures(s) {
                Some(found) => Some(found[1].to_owned()),
                None => s
                    .split_once("Smart contract panicked: ")
                    .map(|(_, reason)| reason.to_owned()),
            },
            Value::Array(items) => items.iter().find_map(panic_in),
            Value::Object(fields) => match fields.get("panic_msg") {
                Some(Value::String(reason)) => Some(reason.clone()),
                _ => fields.values().find_map(panic_in),
            },
            _ => None,
        }
    }
    match panic_in(error) {
        Some(reason) => ChainError::Refused(reason),
        None => ChainError::Unknown(error.to_string()),
    }
}

/// An ed25519 key from its 32-byte seed in hex.
pub fn seed_key(hex: &str) -> Option<SigningKey> {
    let seed: [u8; 32] = hex::decode(hex).ok()?.try_into().ok()?;
    Some(SigningKey::from_bytes(&seed))
}

/// A NEAR secret key as its tools print it: `ed25519:<base58 of seed and public key>`.
pub fn secret_key(tagged: &str) -> Option<SigningKey> {
    let pair: [u8; 64] = untag(tagged)?;
    SigningKey::from_keypair_bytes(&pair).ok()
}

/// Borsh of a NEAR transaction that calls execute_intents on intents.near with `args`, no deposit.
fn execute_intents(signer: &str, public_key: &[u8; 32], nonce: u64, block_hash: &[u8; 32], args: &[u8]) -> Vec<u8> {
    let mut tx = Vec::new();
    let bytes = |tx: &mut Vec<u8>, b: &[u8]| {
        tx.extend((b.len() as u32).to_le_bytes());
        tx.extend(b);
    };
    bytes(&mut tx, signer.as_bytes());
    tx.push(0); // key type: ed25519
    tx.extend(public_key);
    tx.extend(nonce.to_le_bytes());
    bytes(&mut tx, VERIFYING_CONTRACT.as_bytes());
    tx.extend(block_hash);
    tx.extend(1u32.to_le_bytes()); // one action
    tx.push(2); // action: FunctionCall
    bytes(&mut tx, b"execute_intents");
    bytes(&mut tx, args);
    tx.extend(GAS.to_le_bytes());
    tx.extend(0u128.to_le_bytes()); // deposit
    tx
}

/// Borsh of the signed transaction: the transaction, then a signature over its sha256.
fn sign(key: &SigningKey, mut transaction: Vec<u8>) -> Vec<u8> {
    let signature = key.sign(&Sha256::digest(&transaction));
    transaction.push(0); // key type: ed25519
    transaction.extend(signature.to_bytes());
    transaction
}

#[cfg(test)]
mod tests {
    use super::*;

    // Produced by near-api-js 4.0.4 (createTransaction + functionCall + sign) for the same inputs.
    // A transaction encoded any other way is rejected by every node, and no voucher settles.
    #[test]
    fn encodes_and_signs_a_transaction_as_near_api_js_does() {
        let key = secret_key(
            "ed25519:4VZdodJgBy6dxMgm45zusmRzrPvKtiumu5YrK9RLPJAVbW5qTGHqsYeFR8HsFWEh71pjwJffSPkmficrRvk3p3a",
        )
        .unwrap();
        let tx = execute_intents(
            "relayer.near",
            key.verifying_key().as_bytes(),
            123456789012345,
            &[9; 32],
            br#"{"signed":[{"a":1}]}"#,
        );
        assert_eq!(hex::encode(&tx), "0c00000072656c617965722e6e65617200ed4928c628d1c2c6eae90338905995612959273a5c63f93636c14614ac8737d179df0d86487000000c000000696e74656e74732e6e656172090909090909090909090909090909090909090909090909090909090909090901000000020f000000657865637574655f696e74656e7473140000007b227369676e6564223a5b7b2261223a317d5d7d00c06e31d910010000000000000000000000000000000000");
        assert_eq!(
            STANDARD.encode(sign(&key, tx)),
            "DAAAAHJlbGF5ZXIubmVhcgDtSSjGKNHCxurpAziQWZVhKVknOlxj+TY2wUYUrIc30XnfDYZIcAAADAAAAGludGVudHMubmVhcgkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJAQAAAAIPAAAAZXhlY3V0ZV9pbnRlbnRzFAAAAHsic2lnbmVkIjpbeyJhIjoxfV19AMBuMdkQAQAAAAAAAAAAAAAAAAAAAAAAAPDbVIaWuhrFnP4GMd7vrGQmX32eImYjO3+1Ji2puDe4EIVBvPjKIK8WHWPo+MnBSOHT71Vrdb5k/uk+EajQLAs="
        );
    }

    // "Refused" is an answer about the voucher and stops the gas; anything else means try again.
    // Getting this backwards either burns gas on a voucher that cannot settle or drops one that can.
    #[test]
    fn tells_a_contract_refusal_from_an_outage() {
        let refused = |reason: &str| ChainError::Refused(reason.into());
        let debug_text = json!({ "error": "wasm execution failed with error: HostError(GuestPanic { panic_msg: \"insufficient balance or overflow\" })" });
        assert_eq!(classify(&debug_text), refused("insufficient balance or overflow"));
        let sentence = json!({ "ActionError": { "kind": { "FunctionCallError": { "ExecutionError": "Smart contract panicked: deadline has expired" } } } });
        assert_eq!(classify(&sentence), refused("deadline has expired"));
        let structured = json!({ "cause": { "info": { "vm_error": { "HostError": { "GuestPanic": { "panic_msg": "invalid signature" } } } } } });
        assert_eq!(classify(&structured), refused("invalid signature"));
        assert!(matches!(
            classify(&json!({ "name": "REQUEST_VALIDATION_ERROR", "message": "Timeout" })),
            ChainError::Unknown(_)
        ));

        // A transaction that ran and failed for any other reason (say, out of gas) is still an answer.
        let out_of_gas = json!({ "ActionError": { "kind": { "FunctionCallError": { "ExecutionError": "Exceeded the prepaid gas." } } } });
        assert!(matches!(classify(&out_of_gas), ChainError::Unknown(_)));
        assert!(matches!(failed(&out_of_gas), ChainError::Refused(_)));
        assert_eq!(failed(&sentence), refused("deadline has expired"));
    }
}
