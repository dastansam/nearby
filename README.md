# NearBy

Offline payments relayed phone-to-phone over Bluetooth and Wi-Fi ([Nearby Connections](https://developers.google.com/nearby/connections/overview) on Android, [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity) on iOS) and settled on NEAR through [NEAR Intents](https://docs.near-intents.org).

> Pay anyone nearby, even with no signal. Settled on NEAR.

## How it works

1. **Top up (online):** the app makes an offline ed25519 key. Its NEAR implicit account is funded inside `intents.near` (USDC or wNEAR via `ft_transfer_call`), and a bond of NEAR is locked for it in the bond contract: what cheating costs.
2. **Pay (offline):** the payer signs a NEP-413 `transfer` intent (the *voucher*) with a random 32-byte nonce. Nonces are unordered, so many vouchers can be signed in parallel and settle in any order.
3. **Verify (offline):** the merchant checks the signature, the deadline and the nonce, then the payer: no payment over 25 USDC, a sequence number not seen before from that payer, a bond of at least 5 NEAR, and a balance the relayer attested in the last 24 h that still covers the payment after subtracting every voucher of that payer the merchant's phone has seen. The attestation (balance and bond) travels with the voucher, in the QR code and over the relay.
4. **Relay (offline):** every phone keeps an outbox; when two phones connect they send each other the vouchers the other lacks, until one of them reaches the internet.
5. **Settle (online):** any phone with a signal uploads what it holds to the relayer, which submits each voucher to `intents.near` via `execute_intents` and pays gas.
6. **Punish (online):** two vouchers from one key with the same sequence number are proof of a double-spend. The relayer hands the pair to the bond contract, which checks both signatures itself; the key forfeits its bond and is banned.
7. **Confirm:** the relayer signs a receipt for each voucher it settles. The uploading phone keeps it and hands it to any phone still carrying that voucher, which marks it settled and stops carrying it. A merchant with a signal sees the chain's answer on the receive screen within seconds of accepting.

## Run it

Rust 1.95+ for the workspace (`relayer/`, `bond/`, `voucher/`).

Bond contract, from `bond/` (needs [cargo-near](https://github.com/near/cargo-near) and the [near CLI](https://github.com/near/near-cli-rs)):

```sh
cargo near build non-reproducible-wasm --no-abi --profile contract
near contract deploy bond.you.near use-file ../target/near/nearby_bond/nearby_bond.wasm \
  without-init-call network-config mainnet sign-with-keychain send
# lock a bond for an offline account (anyone can pay it; the offline account holds only USDC)
near contract call-function as-transaction bond.you.near bond_for json-args '{"account":"<64 hex>"}' \
  prepaid-gas '30 Tgas' attached-deposit '5 NEAR' sign-as you.near network-config mainnet sign-with-keychain send
```

At least 1 NEAR per call. Whoever paid first owns the bond and alone may add to it (it all leaves with them): `unbond(account)` then `withdraw(account)` 7 days later return it to them. Views: `bond_of` (what backs payments now: 0 while unbonding or banned), `at_stake` (what a proof would take: the bond, unbonding or not) and `is_banned`. `slash(a, b)` takes two signed vouchers; a key with nothing at stake is turned away, not banned.

Relayer, from `relayer/`:

```sh
RELAYER_ACCOUNT=you.near RELAYER_KEY=ed25519:... ATTESTATION_SK=<64 hex chars> BOND_CONTRACT=bond.you.near cargo run --release
```

`RELAYER_ACCOUNT` is a mainnet account with NEAR for gas. It only pays gas: a voucher's own signature moves the tokens, and the bond contract decides a slashing. Each pair of equivocating vouchers goes to `slash` once there is something at stake, and `GET /equivocations` lists the pairs with the slashing transaction or the contract's refusal. `GET /` prints the attestation key.

App, from `app/`, pointing at the relayer:

```sh
flutter build apk --debug \
  --dart-define=RELAYER_URL=http://<relayer host>:8787 \
  --dart-define=RELAYER_KEY=ed25519:<attestation key from GET />
```

For iPhones, with Xcode signed into the developer account: `flutter run -d <iphone>` with the same `--dart-define`s, or `flutter build ipa` for TestFlight. The project carries our signing team; another team changes it in Xcode under Signing & Capabilities.

Debug builds may use plain `http`; release and TestFlight builds need `https`. Without `RELAYER_URL` the app still pays, receives and relays, but never uploads. Without `RELAYER_KEY` there is no relayer whose balance attestations the app trusts, so payees skip the balance check (the receive screen says so) and enforce only the 25 USDC limit and the sequence numbers.

Tests: `cargo test` at the root (relayer and voucher), `cargo test -p nearby-bond`, `flutter test` in `app/`.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android and iOS): offline wallet, voucher signing/verification, QR pay and receive, phone-to-phone relay, upload to the relayer |
| `app/ios/Runner/Multipeer.swift` | The iOS radio: Multipeer Connectivity behind the same `Transport` interface as Android's Nearby Connections |
| `relayer/` | Rust service: receives vouchers, calls `execute_intents`, signs balance attestations, keeps pairs of vouchers that prove a double-spend |
| `relayer/src/bin/settle-test.rs` | Gate 1: sign a voucher now, submit it later, see whether it settles (`cargo run --bin settle-test -- sign`, then `submit`) |
| `bond/` | NEAR contract (Rust, near-sdk): bonds in NEAR, `slash` with two equivocating vouchers, key bans |
| `voucher/` | The voucher format shared by the relayer and the contract: shapes, NEP-413 hash, memo parsing |
| `docs/` | Spec and threat model |
| `testdata/` | Voucher, balance attestation and settlement receipt test vectors shared by the Dart and Rust code |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment.

Not yet proven: no voucher has settled with a funded account (only dry runs against mainnet), and the phone-to-phone relay has only run in tests, not on phones.

The relay is per platform: iPhones find iPhones, Android phones find Android phones, and the two never find each other. Everything else, including the QR path, works across the two.

Double-spending offline is bounded, provable and punished, not prevented. A merchant with a signal need not take the risk: the payment is uploaded the moment it is accepted and the receive screen shows the chain's answer within seconds, settled, refused for good, or turned down for now with the reason (the payer's balance is short). A payer can still overspend across merchants who are offline and have not seen each other's vouchers, up to 25 USDC each, for as long as their attestation lasts. Two vouchers with one sequence number prove it; the relayer hands the pair to the bond contract, and the key forfeits its bond (5 NEAR or more) and is banned. The forfeited bond stays in the contract: paying it to the vouchers' receivers would let a cheat name their own accounts and slash themselves, and compensating the merchant left unpaid needs settlement evidence the contract does not have. The contract has 17 unit tests and has not been deployed or slashed on mainnet yet; the bond is in NEAR while the budget is in USDC, so the two are not compared, and a payer cheating many merchants in one afternoon can still take more than the bond.

Settlements travel back into the mesh: the relayer signs a receipt `{voucher, tx, block}` for each voucher it settles, and a phone that holds one hands it to any peer still carrying that voucher, which marks it settled and stops carrying it. A merchant whose phone stays offline learns of a customer's earlier payment settling when the customer (or anyone who synced) comes back, and until then counts it against them: a returning customer can still be refused before that happens, although their new attested balance already reflects the payment.

One known rough edge of the offline check:

- A refusal cannot unsign a voucher. A payment the merchant's phone refused can still be carried to the relayer and settle; the receive screen says so.

## What works, what's next

Everything in the first table runs in the automated tests (Rust: relayer, bond contract, shared voucher crate; Dart: app). Nothing has yet run on phones or spent real money; see Status.

| Works | Where |
| --- | --- |
| Offline ed25519 key; NEP-413 voucher signing and checking, byte-identical in Dart and Rust (`testdata/voucher-vector.json`), dry-run against mainnet `simulate_intents` | `app/lib/voucher/`, `voucher/` |
| Payment request QR, voucher by radio or QR, payee checks: signature, request id, deadline, nonce, cap, sequence chain, bond, attested balance minus vouchers seen | `app/lib/screens/`, `app/lib/voucher/guards.dart` |
| Store-and-forward gossip (have / want / voucher / settled) over Nearby Connections on Android and Multipeer Connectivity on iOS, hop limit 8 | `app/lib/mesh/`, `app/android/`, `app/ios/` |
| Relayer: `execute_intents` settlement, nonce-spent detection, refusals, balance attestations, settlement receipts, double-spend pairs to the bond contract, `GET /equivocations` | `relayer/` |
| Bond contract: bond in NEAR, 7-day unbonding, `slash` recomputes both hashes and verifies both signatures on chain, forfeit and ban | `bond/` |
| Receipts carried back into the mesh; the receive screen shows settled / refused / turned down live when the phone has a signal | `app/lib/mesh/gossip.dart`, `app/lib/screens/receive.dart` |

| Next | Why not yet |
| --- | --- |
| One funded settlement and one slash on mainnet, with explorer links | Needs a funded offline account and the bond contract deployed |
| Running on phones: Android (Nearby Connections) and iPhone (Multipeer) | Only tests so far |
| Compensating the unpaid merchant from a forfeited bond | The contract has no settlement evidence; paying the vouchers' receivers would let a cheat slash themselves |
| Hardware-held offline keys (StrongBox / Secure Enclave), attested by the relayer | Stretch in the spec |
| Pruning settled and expired vouchers from the store | Nothing is pruned yet; relays refuse vouchers valid longer than 7 days as a stopgap |
| Receipts pushed to peers already connected | They go out in reply to the next `have` |
| Who pays gas: a fee per voucher or a sponsor | Open question; the relayer pays today |

## Libraries

App (Flutter): `cryptography` (ed25519, sha256), `crypto`, `bs58`, `convert`, `sqflite`, `qr_flutter`, `mobile_scanner`, `flutter_secure_storage`, `http`, `nearby_connections`, `permission_handler`; on iOS, Apple's Multipeer Connectivity through a small Swift plugin.
Relayer (Rust): `axum`, `tokio`, `reqwest`, `ed25519-dalek`, `serde` / `serde_json`, `sha2`, `base64`, `bs58`, `hex`, `rand`, `regex`, `chrono`.
Bond contract (Rust): `near-sdk`. Shared voucher crate: `serde_json`, `sha2`, `bs58`, `base64`, `hex`, with `ed25519-dalek` and `rand` behind the `sign` feature.

## License

MIT. See [LICENSE](LICENSE).
