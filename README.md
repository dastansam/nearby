# NearBy

Offline payments relayed phone-to-phone over the [qaul](https://qaul.net) mesh and settled on NEAR through [NEAR Intents](https://docs.near-intents.org).

> Pay anyone nearby, even with no signal. Settled on NEAR.

## How it works

1. **Top up (online):** the app makes an offline ed25519 key. Its NEAR implicit account is funded inside `intents.near` (USDC or wNEAR via `ft_transfer_call`).
2. **Pay (offline):** the payer signs a NEP-413 `transfer` intent (the *voucher*) with a random 32-byte nonce (4-byte salt + 28 random bytes). Nonces are unordered, so many vouchers can be signed in parallel and settle in any order.
3. **Verify (offline):** the merchant checks the signature, the deadline, the nonce and the cached balance attestation.
4. **Relay (offline):** the voucher travels as a qaul delay-tolerant message to the relayer's qaul ID.
5. **Settle (online):** the relayer submits vouchers to `intents.near` via `execute_intents` and pays gas.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android first): wallet, voucher signing/verification, qaul transport |
| `relayer/` | TypeScript service: receives vouchers, calls `execute_intents`, signs balance attestations |
| `relayer/scripts/salt-test.ts` | Gate 1: sign a voucher now, submit it later, see whether it settles |
| `docs/` | Spec and threat model |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment.

## License

AGPL-3.0-or-later (qaul's libqaul is AGPL-3.0).
