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

`NEAR_RPC` is an ordered, comma-separated list of nodes (default: the two public ones). One that cannot be reached is skipped for the next; put a provider you have a key for first. A transaction is sent again elsewhere only when the first node was never reached, not after a timeout.

Before it listens, the relayer checks its account, its key and the bond contract against the network and says what is wrong if one is (`SKIP_PREFLIGHT=1` skips that). It logs a line to stderr for each upload, settlement, refusal and slashing, prints the attestation key at start-up, and answers `GET /healthz`. With `STATE_FILE=/path/state.jsonl` it keeps the first voucher of every sequence number and every double-spend found across restarts; without it a restart between a payer's two vouchers lets the cheat go unpunished, and it says so at start-up. A pair not yet slashed is retried every minute until the bond contract answers, since the vouchers have settled by then and no phone uploads them again. As a container: `docker build -t nearby-relayer .`, then run it with a volume on `/data` and the variables above (`--env-file`).

The app never signs two vouchers with one sequence number, so a double-spend has to be made by hand. With a relayer running and a bond locked (`bond_for`, at least 1 NEAR) for a key of its own, which the contract then bans for good:

```sh
OFFLINE_SK=<64 hex> RELAYER_URL=http://<relayer host>:8787 RECEIVER=a.near OTHER_RECEIVER=b.near \
  cargo run --release --bin settle-test -- cheat
```

It signs two payments with one sequence number, uploads both and prints the slashing transaction when the bond contract has answered. The payments need no balance: the pair is proof whether or not they settle.

App, from `app/`, pointing at the relayer:

```sh
flutter build apk --debug \
  --dart-define=RELAYER_URL=http://<relayer host>:8787 \
  --dart-define=RELAYER_KEY=ed25519:<attestation key from GET />
```

For iPhones, with Xcode signed into the developer account: `flutter run -d <iphone>` with the same `--dart-define`s, or `flutter build ipa` for TestFlight. The project carries our signing team; another team changes it in Xcode under Signing & Capabilities.

Payees refuse a payer with less than 5 NEAR bonded; `--dart-define=MIN_BOND_NEAR=1` lowers that for one build, which is how the demo build is made: cheating costs 1 NEAR there, not 5.

Debug builds may use plain `http`; release and TestFlight builds need `https`. An Android release is signed with the debug key unless `app/android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`; git-ignored) names your own key: sign the one you publish. Without `RELAYER_URL` the app still pays, receives and relays, but never uploads. Without `RELAYER_KEY` there is no relayer whose balance attestations the app trusts, so payees skip the balance check (the receive screen says so) and enforce only the 25 USDC limit and the sequence numbers.

Tests: `cargo test` at the root (relayer and voucher), `cargo test -p nearby-bond`, `flutter test` in `app/`. `cargo test -p nearby-relayer live_ -- --ignored` asks a real mainnet node two questions for free: does it accept our `send_tx` encoding, and do the start-up checks name their mistakes.

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (Android and iOS): offline wallet, voucher signing/verification, QR pay and receive, phone-to-phone relay, upload to the relayer |
| `app/ios/Runner/Multipeer.swift` | The iOS radio: Multipeer Connectivity behind the same `Transport` interface as Android's Nearby Connections |
| `relayer/` | Rust service: receives vouchers, calls `execute_intents`, signs balance attestations, keeps pairs of vouchers that prove a double-spend |
| `relayer/src/bin/settle-test.rs` | Gate 1: sign a voucher now, submit it later, see whether it settles (`cargo run --bin settle-test -- sign`, then `submit`); and `cheat`, which makes a double-spend and waits for the slashing |
| `bond/` | NEAR contract (Rust, near-sdk): bonds in NEAR, `slash` with two equivocating vouchers, key bans |
| `voucher/` | The voucher format shared by the relayer and the contract: shapes, NEP-413 hash, memo parsing |
| `docs/` | Spec and threat model |
| `testdata/` | Voucher, balance attestation and settlement receipt test vectors shared by the Dart and Rust code |

## Status

Hackathon build for NEAR Hackathon (submissions close 2026-11-14 23:59 UTC). Mainnet only: Intents has no testnet deployment. The author is also part of [ainek](https://github.com/sadabaevb/ainek), another project in the same hackathon.

Run on mainnet on 2026-11-14, through the relayer, with throwaway keys: a 0.10 USDC voucher [settled](https://nearblocks.io/txns/CAF2mqAyH4t6WHX5h1qtDQrvvwhbwkQtAyQGYEz15GhQ) on `intents.near`, and a double-spend made with `settle-test cheat` was [slashed](https://nearblocks.io/txns/7mmL3JL7cRwQyQVv3cPQuxMHnFmtcZrTM445iSkX5uQb) by the bond contract, which banned the key and took its 1 NEAR bond. The voucher was uploaded seconds after it was signed, not a day later, and it was signed by the test tool, not by a phone.

Not yet proven: the phone-to-phone relay has only run in tests, not on phones.

The relay is per platform: iPhones find iPhones, Android phones find Android phones, and the two never find each other. Everything else, including the QR path, works across the two.

Double-spending offline is bounded, provable and punished, not prevented. A merchant with a signal need not take the risk: the payment is uploaded the moment it is accepted and the receive screen shows the chain's answer within seconds, settled, refused for good, or turned down for now with the reason (the payer's balance is short). A payer can still overspend across merchants who are offline and have not seen each other's vouchers, up to 25 USDC each, for as long as their attestation lasts. Two vouchers with one sequence number prove it; the relayer hands the pair to the bond contract, and the key forfeits its bond (5 NEAR or more) and is banned. The forfeited bond stays in the contract: paying it to the vouchers' receivers would let a cheat name their own accounts and slash themselves, and compensating the merchant left unpaid needs settlement evidence the contract does not have. The contract has 19 unit tests and one slashing on mainnet (above), on an account whose key we hold, so that deployment is a demonstration and not a place to lock a real bond; the bond is in NEAR while the budget is in USDC, so the two are not compared, and a payer cheating many merchants in one afternoon can still take more than the bond.

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
| Relayer: `execute_intents` settlement, nonce-spent detection, refusals, balance attestations, settlement receipts, double-spend pairs to the bond contract (kept across restarts, retried until answered), `GET /equivocations`, start-up checks, logs, `GET /healthz`, a Dockerfile | `relayer/` |
| Bond contract: bond in NEAR, 7-day unbonding, `slash` recomputes both hashes and verifies both signatures on chain, forfeit and ban | `bond/` |
| Receipts carried back into the mesh; the receive screen shows settled / refused / turned down live when the phone has a signal | `app/lib/mesh/gossip.dart`, `app/lib/screens/receive.dart` |

| Next | Why not yet |
| --- | --- |
| One funded settlement and one slash on mainnet, with explorer links | Needs a funded offline account and the bond contract deployed |
| Running on phones: Android (Nearby Connections) and iPhone (Multipeer) | Only tests so far |
| Bond ownership bound to the payer's key | Today whoever bonds an account first owns its bond, so a stranger can bond one for 1 NEAR and keep its wallet from bonding it |
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
