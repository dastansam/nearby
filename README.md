# NearBy

Offline payments relayed phone-to-phone over Bluetooth and Wi-Fi ([Nearby Connections](https://developers.google.com/nearby/connections/overview)) and settled on NEAR through [NEAR Intents](https://docs.near-intents.org).

> Pay anyone nearby, even with no signal. Settled on NEAR.

## How it works

1. **Top up (online):** the app makes an offline ed25519 key. Its NEAR implicit account is funded inside `intents.near` (USDC or wNEAR via `ft_transfer_call`).
2. **Pay (offline):** the payer signs a NEP-413 `transfer` intent (the *voucher*) with a random 32-byte nonce. Nonces are unordered, so many vouchers can be signed in parallel and settle in any order.
3. **Verify (offline):** the merchant checks the signature, the deadline and the nonce, then the payer: no payment over 25 USDC, a sequence number not seen before from that payer, and a balance the relayer attested in the last 24 h that still covers the payment after subtracting every voucher of that payer the merchant's phone has seen. The attestation travels with the voucher, in the QR code and over the relay.
4. **Relay (offline):** every phone keeps an outbox; when two phones connect they send each other the vouchers the other lacks, until one of them reaches the internet.
5. **Settle (online):** any phone with a signal uploads what it holds to the relayer, which submits each voucher to `intents.near` via `execute_intents` and pays gas.

## Run it

Relayer (Rust 1.85+), from `relayer/`:

```sh
RELAYER_ACCOUNT=you.near RELAYER_KEY=ed25519:... ATTESTATION_SK=<64 hex chars> cargo run --release
```

`RELAYER_ACCOUNT` is a mainnet account with NEAR for gas. It only pays gas: a voucher's own signature moves the tokens. `GET /` prints the attestation key.

App, from `app/`, pointing at the relayer:

```sh
flutter build apk --debug \
  --dart-define=RELAYER_URL=http://<relayer host>:8787 \
  --dart-define=RELAYER_KEY=ed25519:<attestation key from GET />
```

Debug builds may use plain `http`; release builds need `https`. Without `RELAYER_URL` the app still pays, receives and relays, but never uploads. Without `RELAYER_KEY` there is no relayer whose balance attestations the app trusts, so payees skip the balance check (the receive screen says so) and enforce only the 25 USDC limit and the sequence numbers.

Tests: `cargo test` in `relayer/`, `flutter test` in `app/`.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android): offline wallet, voucher signing/verification, QR pay and receive, phone-to-phone relay, upload to the relayer |
| `relayer/` | Rust service: receives vouchers, calls `execute_intents`, signs balance attestations, keeps pairs of vouchers that prove a double-spend |
| `relayer/src/bin/settle-test.rs` | Gate 1: sign a voucher now, submit it later, see whether it settles (`cargo run --bin settle-test -- sign`, then `submit`) |
| `docs/` | Spec and threat model |
| `testdata/` | Voucher and balance attestation test vectors shared by the Dart and Rust code |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment.

Not yet proven: no voucher has settled with a funded account (only dry runs against mainnet), and the phone-to-phone relay has only run in tests, not on phones.

Double-spending offline is bounded and provable, not prevented. A payer can still overspend across merchants who have not seen each other's vouchers, up to 25 USDC each. Two vouchers with one sequence number prove it, and the relayer keeps such pairs, but the bond contract that would punish it is not built yet.

Two known rough edges of the offline check:

- A merchant whose phone stays offline counts a customer's earlier payment against them until that phone learns it settled, so a returning customer can be refused although their new attested balance already reflects it. Nothing tells an offline phone about settlements yet.
- A refusal cannot unsign a voucher. A payment the merchant's phone refused can still be carried to the relayer and settle; the receive screen says so.

## License

MIT. See [LICENSE](LICENSE).
