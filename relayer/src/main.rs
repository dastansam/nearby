//! Runs the relayer. Needs:
//!   RELAYER_ACCOUNT, RELAYER_KEY  a mainnet account with NEAR for gas and its ed25519:... key. It only
//!                                 pays gas: a voucher's own signature is what moves tokens.
//!   BOND_CONTRACT                 the deployed bond contract, asked for every payer's bond.
//!   ATTESTATION_SK                hex ed25519 seed that signs balance attestations. The start-up
//!                                 line and GET / give the public key to pin in the app. Keep it
//!                                 separate from RELAYER_KEY.
//! Optional: NEAR_RPC, PORT (default 8787),
//!   STATE_FILE      where double-spends found are kept across restarts (without it they are lost),
//!   SKIP_PREFLIGHT  set to 1 to start without checking the account, key and bond contract first.
use chrono::Utc;
use nearby_relayer::chain::{seed_key, NearChain};
use nearby_relayer::server::router_with;
use nearby_relayer::settle::Settler;
use nearby_relayer::voucher::tag;
use nearby_relayer::{env, log};
use std::path::Path;
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

    if env("SKIP_PREFLIGHT").as_deref() != Some("1") {
        for line in chain.preflight().await? {
            log(line);
        }
    }
    let chain = Arc::new(chain);
    let settler = match env("STATE_FILE") {
        Some(path) => {
            Settler::with_journal(chain.clone(), Path::new(&path)).map_err(|e| format!("STATE_FILE {path}: {e}"))?
        }
        None => {
            log("STATE_FILE is not set: a restart forgets the double-spends found so far");
            Settler::new(chain.clone())
        }
    };
    log(format!(
        "attestation key (pin it in the app as RELAYER_KEY): {}",
        tag(attestation_key.verifying_key().as_bytes())
    ));

    settler.keep_sweeping();
    let app = router_with(settler, chain, attestation_key, Utc::now);
    // All interfaces: the phones reach the relayer over the network, not from this machine.
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .map_err(|e| e.to_string())?;
    log(format!("listening on port {port}"));
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await
        .map_err(|e| e.to_string())
}

/// Resolves on Ctrl-C, or on SIGTERM, which is how a container is asked to stop.
async fn shutdown() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    log("shutting down");
}
