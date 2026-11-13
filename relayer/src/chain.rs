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
    /// yoctoNEAR backing the account's payments in the bond contract: "0" when there is none.
    fn bond_of(&self, account: &str) -> impl Future<Output = Result<String, ChainError>> + Send;
    /// Hands a pair of equivocating vouchers signed by `signer` to the bond contract, paying gas,
    /// and returns the transaction hash. Refused if the key has nothing at stake or was slashed
    /// already, or if the contract finds the pair no proof.
    fn slash(
        &self,
        signer: &str,
        a: &SignedVoucher,
        b: &SignedVoucher,
    ) -> impl Future<Output = Result<String, ChainError>> + Send;
}

/// The most gas one transaction may use; the call gets all of it and is charged only what it burns.
const GAS: u64 = 300_000_000_000_000;

/// intents.near, and the bond contract if there is one, on mainnet over JSON-RPC.
pub struct NearChain {
    http: reqwest::Client,
    rpc: String,
    account: String,
    key: SigningKey,
    bond_contract: String,
    /// The last access-key nonce this process used. The node answering a view can be a block
    /// behind the one that ran our previous transaction, and would hand the same nonce out again.
    /// Held from choosing the next nonce until the transaction has run: two in flight at once (a
    /// settlement and a slashing, say) would take consecutive nonces, and the chain rejects
    /// whichever lands second.
    last_nonce: tokio::sync::Mutex<u64>,
}

impl NearChain {
    /// `account` pays the gas with `key`, one of its access keys.
    pub fn new(account: String, key: SigningKey, rpc: Option<String>, bond_contract: String) -> Self {
        Self {
            // send_tx answers only once the transaction has run, which takes a few blocks.
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()
                .expect("an HTTP client"),
            rpc: rpc.unwrap_or_else(|| "https://rpc.mainnet.near.org".into()),
            account,
            key,
            bond_contract,
            last_nonce: tokio::sync::Mutex::new(0),
        }
    }

    /// The relayer account from RELAYER_ACCOUNT and RELAYER_KEY, the bond contract from
    /// BOND_CONTRACT, on NEAR_RPC if that is set.
    pub fn from_env() -> Result<Self, &'static str> {
        let usage = "set RELAYER_ACCOUNT, RELAYER_KEY (ed25519:...) and BOND_CONTRACT";
        let key = env("RELAYER_KEY").as_deref().and_then(secret_key).ok_or(usage)?;
        let account = env("RELAYER_ACCOUNT").ok_or(usage)?;
        let bond_contract = env("BOND_CONTRACT").ok_or(usage)?;
        Ok(Self::new(account, key, env("NEAR_RPC"), bond_contract))
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

    /// A view call, with the height it ran at.
    async fn view(&self, contract: &str, method: &str, args: Value) -> Result<At<Value>, ChainError> {
        let query = json!({
            "request_type": "call_function",
            "finality": "optimistic",
            "account_id": contract,
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

    /// A yoctoNEAR amount the bond contract reports for `account`, as decimal text.
    async fn yocto(&self, method: &str, account: &str) -> Result<String, ChainError> {
        let At { value, .. } = self
            .view(&self.bond_contract, method, json!({ "account": account }))
            .await
            .map_err(ChainError::not_a_refusal)?;
        value
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| ChainError::Unknown(format!("{method} is not a string: {value}")))
    }

    /// Checks the setup before the first voucher arrives, so a wrong account, key or bond contract
    /// stops the relayer at the start instead of failing a payment in front of a customer. Returns
    /// what to tell the operator, or why it cannot run.
    pub async fn preflight(&self) -> Result<Vec<String>, String> {
        /// A settlement reserves 0.03 NEAR for its prepaid gas until the unused part is refunded.
        const LOW: u128 = 500_000_000_000_000_000_000_000;
        let public_key = self.key.verifying_key().to_bytes();
        let account = self
            .call(
                "query",
                json!({ "request_type": "view_account", "finality": "final", "account_id": self.account }),
            )
            .await
            .map_err(|e| {
                format!(
                    "RELAYER_ACCOUNT {} cannot be read on the network: {}",
                    self.account,
                    e.reason()
                )
            })?;
        let balance: u128 = account["amount"]
            .as_str()
            .and_then(|amount| amount.parse().ok())
            .ok_or_else(|| format!("RELAYER_ACCOUNT {} has no balance in {account}", self.account))?;
        self.call(
            "query",
            json!({ "request_type": "view_access_key", "finality": "final", "account_id": self.account, "public_key": tag(&public_key) }),
        )
        .await
            .map_err(|e| {
                format!(
                    "RELAYER_KEY is not an access key of {}: {}",
                    self.account,
                    e.reason()
                )
            })?;
        self.yocto("bond_of", &"0".repeat(64)).await.map_err(|e| {
            format!(
                "BOND_CONTRACT {} does not answer bond_of: {}",
                self.bond_contract,
                e.reason()
            )
        })?;
        let near = balance as f64 / 1e24;
        let mut lines = vec![format!(
            "{} holds {near:.3} NEAR, its key is valid, {} answers",
            self.account, self.bond_contract
        )];
        if balance < LOW {
            lines.push(format!(
                "WARNING: {near:.3} NEAR is low for paying gas; top up {}",
                self.account
            ));
        }
        Ok(lines)
    }

    /// Calls `method` on `contract` with `args` and no deposit, paying gas, and returns the
    /// transaction hash once it has run. Refused if the call failed.
    async fn send(&self, contract: &str, method: &str, args: Value) -> Result<String, ChainError> {
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
        let mut last_nonce = self.last_nonce.lock().await;
        let nonce = (*last_nonce).max(seen) + 1;
        *last_nonce = nonce;
        let block_hash: [u8; 32] = block["header"]["hash"]
            .as_str()
            .and_then(untag)
            .ok_or_else(|| unexpected("block", &block))?;

        let args = args.to_string();
        let transaction = function_call(
            &self.account,
            &public_key,
            nonce,
            &block_hash,
            contract,
            method,
            args.as_bytes(),
        );
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

impl Chain for NearChain {
    async fn balance_of(&self, account: &str, token: &str) -> Result<At<String>, ChainError> {
        let At { value, block } = self
            .view(
                VERIFYING_CONTRACT,
                "mt_balance_of",
                json!({ "account_id": account, "token_id": token }),
            )
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
            .view(
                VERIFYING_CONTRACT,
                "is_nonce_used",
                json!({ "account_id": account, "nonce": nonce_base64 }),
            )
            .await
            .map_err(ChainError::not_a_refusal)?;
        let used = value
            .as_bool()
            .ok_or_else(|| ChainError::Unknown(format!("is_nonce_used is not a boolean: {value}")))?;
        Ok(At { value: used, block })
    }

    async fn simulate(&self, v: &SignedVoucher) -> Result<(), ChainError> {
        self.view(VERIFYING_CONTRACT, "simulate_intents", json!({ "signed": [v] }))
            .await
            .map(|_| ())
    }

    async fn execute(&self, v: &SignedVoucher) -> Result<String, ChainError> {
        self.send(VERIFYING_CONTRACT, "execute_intents", json!({ "signed": [v] }))
            .await
    }

    async fn bond_of(&self, account: &str) -> Result<String, ChainError> {
        self.yocto("bond_of", account).await
    }

    async fn slash(&self, signer: &str, a: &SignedVoucher, b: &SignedVoucher) -> Result<String, ChainError> {
        // Free views first: pairs are free to make for anyone with a key, and a transaction for a
        // key with nothing to take would cost this relayer gas for nothing. A key already banned
        // was slashed by a transaction whose answer never reached us, or by someone else.
        if self.yocto("at_stake", signer).await? == "0" {
            let banned = self
                .view(&self.bond_contract, "is_banned", json!({ "account": signer }))
                .await
                .map_err(ChainError::not_a_refusal)?;
            let why = if banned.value == true {
                "already slashed"
            } else {
                "nothing at stake"
            };
            return Err(ChainError::Refused(why.into()));
        }
        self.send(&self.bond_contract, "slash", json!({ "a": a, "b": b })).await
    }
}

/// A transaction that ran and failed. Whatever the reason, that is the chain's answer about this
/// voucher: called anything else, every phone would send it again and each try would cost gas.
fn failed(failure: &Value) -> ChainError {
    ChainError::Refused(classify(failure).reason().to_owned())
}

/// An RPC error or failed execution, as a refusal when it is the contract panicking.
fn classify(error: &Value) -> ChainError {
    // The network refused the relayer's own transaction before running it (out of NEAR for gas, a
    // stale nonce): that says nothing about any voucher, and a phone cannot act on the detail.
    if let Some(invalid) = error["error"]["data"]["TxExecutionError"]["InvalidTxError"].as_object() {
        let kind = invalid.keys().next().map_or("unknown", String::as_str);
        return ChainError::Unknown(format!("the relayer cannot send transactions right now ({kind})"));
    }
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
        // Said in the node's own words when it has some, so no one downstream is shown its JSON.
        None => ChainError::Unknown(
            error["error"]["data"]
                .as_str()
                .or_else(|| error["result"]["error"].as_str())
                .map_or_else(|| error.to_string(), str::to_owned),
        ),
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

/// Borsh of a NEAR transaction with one function call, no deposit.
fn function_call(
    signer: &str,
    public_key: &[u8; 32],
    nonce: u64,
    block_hash: &[u8; 32],
    contract: &str,
    method: &str,
    args: &[u8],
) -> Vec<u8> {
    let mut tx = Vec::new();
    let bytes = |tx: &mut Vec<u8>, b: &[u8]| {
        tx.extend((b.len() as u32).to_le_bytes());
        tx.extend(b);
    };
    bytes(&mut tx, signer.as_bytes());
    tx.push(0); // key type: ed25519
    tx.extend(public_key);
    tx.extend(nonce.to_le_bytes());
    bytes(&mut tx, contract.as_bytes());
    tx.extend(block_hash);
    tx.extend(1u32.to_le_bytes()); // one action
    tx.push(2); // action: FunctionCall
    bytes(&mut tx, method.as_bytes());
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
        let tx = function_call(
            "relayer.near",
            key.verifying_key().as_bytes(),
            123456789012345,
            &[9; 32],
            VERIFYING_CONTRACT,
            "execute_intents",
            br#"{"signed":[{"a":1}]}"#,
        );
        assert_eq!(hex::encode(&tx), "0c00000072656c617965722e6e65617200ed4928c628d1c2c6eae90338905995612959273a5c63f93636c14614ac8737d179df0d86487000000c000000696e74656e74732e6e656172090909090909090909090909090909090909090909090909090909090909090901000000020f000000657865637574655f696e74656e7473140000007b227369676e6564223a5b7b2261223a317d5d7d00c06e31d910010000000000000000000000000000000000");
        assert_eq!(
            STANDARD.encode(sign(&key, tx)),
            "DAAAAHJlbGF5ZXIubmVhcgDtSSjGKNHCxurpAziQWZVhKVknOlxj+TY2wUYUrIc30XnfDYZIcAAADAAAAGludGVudHMubmVhcgkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJAQAAAAIPAAAAZXhlY3V0ZV9pbnRlbnRzFAAAAHsic2lnbmVkIjpbeyJhIjoxfV19AMBuMdkQAQAAAAAAAAAAAAAAAAAAAAAAAPDbVIaWuhrFnP4GMd7vrGQmX32eImYjO3+1Ji2puDe4EIVBvPjKIK8WHWPo+MnBSOHT71Vrdb5k/uk+EajQLAs="
        );
    }

    // Against a real node, for nothing: a well-formed transaction from an account that does not
    // exist. A node that cannot parse the encoding or the request says so; one that can says the
    // signer is missing. Run by hand: cargo test -p nearby-relayer live_ -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "needs the network"]
    async fn live_node_parses_our_send_tx() {
        let key = SigningKey::from_bytes(&rand::random());
        let chain = NearChain::new("nobody-nearby-test.near".into(), key.clone(), None, "bond.near".into());
        let block = chain.call("block", json!({ "finality": "final" })).await.unwrap();
        let hash: [u8; 32] = block["header"]["hash"].as_str().and_then(untag).unwrap();
        let tx = function_call(
            "nobody-nearby-test.near",
            key.verifying_key().as_bytes(),
            1,
            &hash,
            VERIFYING_CONTRACT,
            "execute_intents",
            br#"{"signed":[]}"#,
        );
        let sent = json!({ "signed_tx_base64": STANDARD.encode(sign(&key, tx)), "wait_until": "EXECUTED_OPTIMISTIC" });
        let answer = chain.call("send_tx", sent).await;
        println!("node said: {answer:?}");
        let said = format!("{answer:?}");
        assert!(
            !said.contains("PARSE") && !said.contains("Parse") && !said.contains("eserializ"),
            "{said}"
        );
    }

    // The relayer's own transaction can be turned away before it runs. Phones are shown the reason,
    // so it must read as the relayer's problem, in words, and never as a verdict on the voucher.
    #[test]
    fn a_transaction_the_network_turns_away_is_the_relayers_problem_not_the_vouchers() {
        // As mainnet answered a transaction from an account that does not exist.
        let node = json!({"jsonrpc":"2.0","error":{"name":"HANDLER_ERROR","cause":{"info":{},"name":"INVALID_TRANSACTION"},"code":-32000,"message":"Server error","data":{"TxExecutionError":{"InvalidTxError":{"SignerDoesNotExist":{"signer_id":"relayer.near"}}}}},"id":"nearby"});
        assert_eq!(
            classify(&node),
            ChainError::Unknown("the relayer cannot send transactions right now (SignerDoesNotExist)".into())
        );
    }

    // Against a real node. Run by hand: cargo test -p nearby-relayer live_ -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "needs the network"]
    async fn live_preflight_names_the_mistake() {
        let key = SigningKey::from_bytes(&rand::random());
        let nobody = NearChain::new("nobody-nearby-test.near".into(), key.clone(), None, "bond.near".into());
        let said = nobody.preflight().await.unwrap_err();
        println!("{said}");
        assert_eq!(
            said,
            "RELAYER_ACCOUNT nobody-nearby-test.near cannot be read on the network: \
             account nobody-nearby-test.near does not exist while viewing"
        );
        // A real account, a key that is not one of its keys.
        let wrong_key = NearChain::new("intents.near".into(), key, None, "bond.near".into());
        let said = wrong_key.preflight().await.unwrap_err();
        println!("{said}");
        assert!(
            said.starts_with("RELAYER_KEY is not an access key of intents.near: access key ed25519:"),
            "{said}"
        );
        assert!(said.ends_with("does not exist while viewing"), "{said}");
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
