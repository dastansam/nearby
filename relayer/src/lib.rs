//! The NearBy relayer: settles uploaded vouchers on intents.near and signs balance attestations.
pub mod attestation;
pub mod chain;
pub mod server;
pub mod settle;
pub mod voucher;

/// An environment variable, if it is set to something.
pub fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}
