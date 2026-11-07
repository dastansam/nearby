//! HTTP face of the relayer. Nothing here needs authentication: vouchers authorize themselves by
//! signature, balances are public, and an attestation is only as good as the relayer's signature on it.
use crate::attestation::{sign_attestation, Attestation};
use crate::chain::Chain;
use crate::settle::Settler;
use crate::voucher::{iso, tag, SignedVoucher, USDC_TOKEN};
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
    let relayer = Relayer {
        settler: Settler::new(chain.clone()),
        chain,
        attestation_key,
        now,
    };
    Router::new()
        .route("/", get(about::<C>))
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

/// A gateway phone uploads what it carries. One result per voucher, in order.
async fn upload<C: Chain>(
    State(relayer): State<Arc<Relayer<C>>>,
    body: Result<Json<Upload>, JsonRejection>,
) -> Response {
    match body {
        Ok(Json(Upload { vouchers })) if vouchers.len() <= MAX_VOUCHERS => {
            // In a task of its own: a phone that loses its signal mid-upload drops this request, and
            // that must not stop a settlement halfway, with a transaction sent and nothing recorded.
            match tokio::spawn(async move { relayer.settler.settle(&vouchers).await }).await {
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

/// What an offline account holds right now, signed, for the app to show payees while offline.
async fn attest<C: Chain>(State(relayer): State<Arc<Relayer<C>>>, Path(account): Path<String>) -> Response {
    // Offline accounts are implicit ones: the hex of the key that signs their vouchers.
    if account.len() != 64 || !account.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return refuse(StatusCode::BAD_REQUEST, "not an implicit account");
    }
    match relayer.chain.balance_of(&account, USDC_TOKEN).await {
        Ok(read) => {
            let attestation = Attestation {
                account,
                token: USDC_TOKEN.into(),
                balance: read.value,
                bond: "0".into(), // no bond contract yet
                as_of: iso((relayer.now)()),
                block: read.block,
            };
            Json(sign_attestation(&relayer.attestation_key, &attestation)).into_response()
        }
        Err(e) => refuse(StatusCode::INTERNAL_SERVER_ERROR, e.reason()),
    }
}

/// Proofs of double-spending seen so far, for whoever submits them to the bond contract.
async fn equivocations<C: Chain>(State(relayer): State<Arc<Relayer<C>>>) -> Json<Vec<(SignedVoucher, SignedVoucher)>> {
    Json(relayer.settler.equivocations().await)
}
