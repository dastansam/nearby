# NearBy

Offline payments relayed phone-to-phone over Bluetooth and Wi-Fi ([Nearby Connections](https://developers.google.com/nearby/connections/overview)) and settled on NEAR through [NEAR Intents](https://docs.near-intents.org).

> Pay anyone nearby, even with no signal. Settled on NEAR.

## How it works

1. **Top up (online):** the app makes an offline ed25519 key. Its NEAR implicit account is funded inside `intents.near` (USDC or wNEAR via `ft_transfer_call`).
2. **Pay (offline):** the payer signs a NEP-413 `transfer` intent (the *voucher*) with a random 32-byte nonce. Nonces are unordered, so many vouchers can be signed in parallel and settle in any order.
3. **Verify (offline):** the merchant checks the signature, the deadline and the nonce. (Checking a cached balance attestation is not built yet; the relayer already signs them.)
4. **Relay (offline):** every phone keeps an outbox; when two phones connect they send each other the vouchers the other lacks, until one of them reaches the internet.
5. **Settle (online):** any phone with a signal uploads what it holds to the relayer, which submits each voucher to `intents.near` via `execute_intents` and pays gas.

## Run it

Relayer (Node 22+), from `relayer/`:

```sh
npm install
RELAYER_ACCOUNT=you.near RELAYER_KEY=ed25519:... ATTESTATION_SK=<64 hex chars> npm run dev
```

`RELAYER_ACCOUNT` is a mainnet account with NEAR for gas. It only pays gas: a voucher's own signature moves the tokens. `GET /` prints the attestation key.

App, from `app/`, pointing at the relayer:

```sh
flutter build apk --debug --dart-define=RELAYER_URL=http://<relayer host>:8787
```

Debug builds may use plain `http`; release builds need `https`. Without `RELAYER_URL` the app still pays, receives and relays, but never uploads.

Tests: `npm test` in `relayer/`, `flutter test` in `app/`.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android): offline wallet, voucher signing/verification, QR pay and receive, phone-to-phone relay, upload to the relayer |
| `relayer/` | TypeScript service: receives vouchers, calls `execute_intents`, signs balance attestations, keeps pairs of vouchers that prove a double-spend |
| `relayer/scripts/settle-test.ts` | Gate 1: sign a voucher now, submit it later, see whether it settles |
| `docs/` | Spec and threat model |
| `testdata/` | Voucher test vector shared by the Dart and TypeScript signers |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment.

Not yet proven: no voucher has settled with a funded account (only dry runs against mainnet), and the phone-to-phone relay has only run in tests, not on phones.

## License

MIT. See [LICENSE](LICENSE).
