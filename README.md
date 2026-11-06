# NearBy

Offline payments relayed phone-to-phone over Bluetooth and Wi-Fi ([Nearby Connections](https://developers.google.com/nearby/connections/overview)) and settled on NEAR through [NEAR Intents](https://docs.near-intents.org).

> Pay anyone nearby, even with no signal. Settled on NEAR.

## How it works

1. **Top up (online):** the app makes an offline ed25519 key. Its NEAR implicit account is funded inside `intents.near` (USDC or wNEAR via `ft_transfer_call`).
2. **Pay (offline):** the payer signs a NEP-413 `transfer` intent (the *voucher*) with a random 32-byte nonce. Nonces are unordered, so many vouchers can be signed in parallel and settle in any order.
3. **Verify (offline):** the merchant checks the signature, the deadline, the nonce and the cached balance attestation.
4. **Relay (offline):** every phone keeps an outbox; when two phones connect they send each other the vouchers the other lacks, until one of them reaches the internet. (Not built yet.)
5. **Settle (online):** the relayer submits vouchers to `intents.near` via `execute_intents` and pays gas.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android): offline wallet, voucher signing/verification, QR pay and receive |
| `relayer/` | TypeScript service: receives vouchers, calls `execute_intents`, signs balance attestations |
| `relayer/scripts/settle-test.ts` | Gate 1: sign a voucher now, submit it later, see whether it settles |
| `docs/` | Spec and threat model |
| `testdata/` | Voucher test vector shared by the Dart and TypeScript signers |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment.

## License

MIT. See [LICENSE](LICENSE).
