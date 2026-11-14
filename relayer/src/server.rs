//! HTTP face of the relayer. Nothing here needs authentication: vouchers authorize themselves by
//! signature, balances are public, and an attestation is only as good as the relayer's signature on it.
use crate::attestation::{sign_attestation, sign_receipt, Attestation, Receipt};
use crate::chain::Chain;
use crate::log;
use crate::settle::{Outcome, Proof, Settler};
use crate::voucher::{iso, tag, USDC_TOKEN};
use axum::extract::rejection::JsonRejection;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use ed25519_dalek::SigningKey;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

/// A phone's whole outbox fits well under this; more is not a phone.
const MAX_VOUCHERS: usize = 500;

struct Relayer<C> {
    chain: Arc<C>,
    settler: Settler<C>,
    attestation_key: SigningKey,
    now: fn() -> DateTime<Utc>,
}

pub fn router<C: Chain>(chain: Arc<C>, attestation_key: SigningKey, now: fn() -> DateTime<Utc>) -> Router {
    router_with(Settler::new(chain.clone()), chain, attestation_key, now)
}

/// Like [`router`], with a settler of the caller's making (one that keeps a journal, say). The
/// caller starts its sweep ([`Settler::keep_sweeping`]), or double-spends are only retried on a restart.
pub fn router_with<C: Chain>(
    settler: Settler<C>,
    chain: Arc<C>,
    attestation_key: SigningKey,
    now: fn() -> DateTime<Utc>,
) -> Router {
    let relayer = Relayer {
        settler,
        chain,
        attestation_key,
        now,
    };
    Router::new()
        .route("/", get(about::<C>))
        .route("/healthz", get(|| async { Json(json!({ "ok": true })) }))
        .route("/vouchers", post(upload::<C>))
        .route("/attestation/{account}", get(attest::<C>))
        .route("/equivocations", get(equivocations::<C>))
        .with_state(Arc::new(relayer))
}

fn refuse(status: StatusCode, error: &str) -> Response {
    (status, Json(json!({ "error": error }))).into_response()
}

/// The key the app must pin to trust this relayer's attestations.
async fn about<C: Chain>(State(relayer): State<Arc<Relayer<C>>>) -> Json<Value> {
    Json(
        json!({ "name": "nearby-relayer", "attestation_key": tag(relayer.attestation_key.verifying_key().as_bytes()) }),
    )
}

#[derive(Deserialize)]
struct Upload {
    vouchers: Vec<Value>,
}

/// A gateway phone uploads what it carries. One result per voucher, in order. A settled one comes
/// with a signed receipt, for the phones still offline that carry the voucher.
async fn upload<C: Chain>(
    State(relayer): State<Arc<Relayer<C>>>,
    body: Result<Json<Upload>, JsonRejection>,
) -> Response {
    match body {
        Ok(Json(Upload { vouchers })) if vouchers.len() <= MAX_VOUCHERS => {
            log(format!("upload of {} vouchers", vouchers.len()));
            // In a task of its own: a phone that loses its signal mid-upload drops this request, and
            // that must not stop a settlement halfway, with a transaction sent and nothing recorded.
            let settling = tokio::spawn(async move {
                let outcomes = relayer.settler.settle(&vouchers).await;
                outcomes
                    .into_iter()
                    .zip(&vouchers)
                    .map(|(outcome, v)| with_receipt(&relayer.attestation_key, outcome, v))
                    .collect::<Vec<Value>>()
            });
            match settling.await {
                Ok(results) => Json(json!({ "results": results })).into_response(),
                Err(_) => refuse(StatusCode::INTERNAL_SERVER_ERROR, "settlement stopped unexpectedly"),
            }
        }
        _ => refuse(
            StatusCode::BAD_REQUEST,
            &format!("send {{ \"vouchers\": [...] }} with at most {MAX_VOUCHERS}"),
        ),
    }
}

/// The outcome as JSON, with a receipt when this relayer settled the voucher and knows by which block.
/// Not when the chain merely shows the nonce spent: a second voucher on that nonce was not paid.
fn with_receipt(key: &SigningKey, outcome: Outcome, v: &Value) -> Value {
    let mut json = json!(outcome);
    if let (
        Outcome::Settled {
            tx: Some(tx),
            block: Some(block),
        },
        Some(voucher),
    ) = (&outcome, v["signature"].as_str())
    {
        let receipt = Receipt {
            voucher: voucher.to_owned(),
            tx: tx.clone(),
            block: *block,
        };
        json["receipt"] = json!(sign_receipt(key, &receipt));
    }
    json
}

/// What an offline account holds right now, signed, for the app to show payees while offline.
async fn attest<C: Chain>(State(relayer): State<Arc<Relayer<C>>>, Path(account): Path<String>) -> Response {
    // Offline accounts are implicit ones: the hex of the key that signs their vouchers.
    if account.len() != 64 || !account.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return refuse(StatusCode::BAD_REQUEST, "not an implicit account");
    }
    let asked = tokio::try_join!(
        relayer.chain.balance_of(&account, USDC_TOKEN),
        relayer.chain.bond_of(&account)
    );
    let (read, bond) = match asked {
        Ok(answers) => answers,
        Err(e) => return refuse(StatusCode::INTERNAL_SERVER_ERROR, e.reason()),
    };
    log(format!(
        "attested {account}: balance {}, bond {bond}",
        read.value
    ));
    let attestation = Attestation {
        account,
        token: USDC_TOKEN.into(),
        balance: read.value,
        bond,
        as_of: iso((relayer.now)()),
        block: read.block,
    };
    Json(sign_attestation(&relayer.attestation_key, &attestation)).into_response()
}

/// Proofs of double-spending seen so far, with the slashing transaction each one led to.
async fn equivocations<C: Chain>(State(relayer): State<Arc<Relayer<C>>>) -> Json<Vec<Proof>> {
    Json(relayer.settler.equivocations().await)
}
