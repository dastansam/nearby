//! The NearBy relayer: settles uploaded vouchers on intents.near and signs balance attestations.
pub mod attestation;
pub mod chain;
pub mod journal;
pub mod server;
pub mod settle;
pub mod voucher;

/// An environment variable, if it is set to something.
pub fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// One line on stderr: the operator's only view of what the relayer is doing.
pub fn log(what: impl std::fmt::Display) {
    eprintln!("{} {what}", chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"));
}
