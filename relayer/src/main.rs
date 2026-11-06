//! Runs the relayer. Needs:
//!   RELAYER_ACCOUNT, RELAYER_KEY  a mainnet account with NEAR for gas and its ed25519:... key. It only
//!                                 pays gas: a voucher's own signature is what moves tokens.
//!   ATTESTATION_SK                hex ed25519 seed that signs balance attestations. GET / prints the
//!                                 public key to pin in the app. Keep it separate from RELAYER_KEY.
//! Optional: NEAR_RPC, PORT (default 8787).
use chrono::Utc;
use nearby_relayer::chain::{seed_key, NearChain};
use nearby_relayer::env;
use nearby_relayer::server::router;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<(), String> {
    let chain = NearChain::from_env()?;
    let attestation_key = env("ATTESTATION_SK")
        .as_deref()
        .and_then(seed_key)
        .ok_or("set ATTESTATION_SK (64 hex characters)")?;
    let port: u16 = env("PORT")
        .map_or(Ok(8787), |port| port.parse())
        .map_err(|_| "PORT is not a port number")?;

    let app = router(Arc::new(chain), attestation_key, Utc::now);
    // All interfaces: the phones reach the relayer over the network, not from this machine.
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .map_err(|e| e.to_string())?;
    println!("relayer listening on port {port}");
    axum::serve(listener, app).await.map_err(|e| e.to_string())
}
