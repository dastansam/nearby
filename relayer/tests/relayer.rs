//! The settlement rules and the HTTP API, against a stand-in for intents.near.
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Duration, Utc};
use ed25519_dalek::{Signature, SigningKey, Verifier};
use http_body_util::BodyExt;
use nearby_relayer::attestation::ATTESTATION_DOMAIN;
use nearby_relayer::chain::{At, Chain, ChainError};
use nearby_relayer::server::router;
use nearby_relayer::settle::{Outcome, Settler};
use nearby_relayer::voucher::{
    implicit_account, iso, make_nonce, sign_voucher, tag, untag, IntentMessage, SignedVoucher, USDC_TOKEN,
};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use tower::ServiceExt;

const BLOCK: u64 = 223318485;
const AT: &str = "2026-11-10T09:00:00.000Z";

/// What the relayer asked of the chain, and how the chain is to answer.
struct Fake {
    used: HashSet<String>,           // "account:nonce" already settled on chain
    refuse: HashMap<String, String>, // nonce -> the contract's panic message
    down: bool,
    fails_after_executing: bool,  // the chain is lost right after a transaction goes through
    no_answer_to_executing: bool, // the transaction goes out, and the answer never comes back
    lagging: bool,                // the node answering views has not seen what was just executed
    lookups: usize,               // calls made
    executed: Vec<SignedVoucher>,
    block: u64,         // the height every view is answered at
    bond: &'static str, // yoctoNEAR the bond contract reports at stake for every account
    refuse_slash: Option<&'static str>,
    no_answer_to_slashing: bool, // the slashing goes through, and the answer never comes back
    slashed: Vec<(SignedVoucher, SignedVoucher)>,
}

/// A stand-in for intents.near and the bond contract.
struct FakeChain(Mutex<Fake>);

impl FakeChain {
    fn new() -> Arc<Self> {
        let fake = Fake {
            used: HashSet::new(),
            refuse: HashMap::new(),
            down: false,
            fails_after_executing: false,
            no_answer_to_executing: false,
            lagging: false,
            lookups: 0,
            executed: Vec::new(),
            block: BLOCK,
            bond: "5000000000000000000000000",
            refuse_slash: None,
            no_answer_to_slashing: false,
            slashed: Vec::new(),
        };
        Arc::new(Self(Mutex::new(fake)))
    }

    fn state(&self) -> MutexGuard<'_, Fake> {
        self.0.lock().unwrap()
    }

    /// Every call waits its turn like a real network call would, then fails if the chain is down.
    async fn reach(&self) -> Result<MutexGuard<'_, Fake>, ChainError> {
        tokio::task::yield_now().await;
        let mut fake = self.state();
        if fake.down {
            return Err(ChainError::Unknown("fetch failed".into()));
        }
        fake.lookups += 1;
        Ok(fake)
    }
}

impl Chain for FakeChain {
    async fn balance_of(&self, _account: &str, _token: &str) -> Result<At<String>, ChainError> {
        let fake = self.reach().await?;
        Ok(At {
            value: "25000000".into(),
            block: fake.block,
        })
    }

    async fn is_nonce_used(&self, account: &str, nonce: &str) -> Result<At<bool>, ChainError> {
        let fake = self.reach().await?;
        Ok(At {
            value: fake.used.contains(&format!("{account}:{nonce}")),
            block: fake.block,
        })
    }

    async fn simulate(&self, v: &SignedVoucher) -> Result<(), ChainError> {
        let fake = self.reach().await?;
        fake.refuse
            .get(&v.payload.nonce)
            .map_or(Ok(()), |why| Err(ChainError::Refused(why.clone())))
    }

    async fn execute(&self, v: &SignedVoucher) -> Result<String, ChainError> {
        let mut fake = self.reach().await?;
        fake.executed.push(v.clone());
        if fake.no_answer_to_executing {
            return Err(ChainError::Unknown("timed out".into()));
        }
        if !fake.lagging {
            let message: IntentMessage = serde_json::from_str(&v.payload.message).unwrap();
            fake.used.insert(format!("{}:{}", message.signer_id, v.payload.nonce));
        }
        fake.down = fake.fails_after_executing;
        Ok(format!("tx{}", fake.executed.len()))
    }

    async fn bond_of(&self, _account: &str) -> Result<String, ChainError> {
        Ok(self.reach().await?.bond.into())
    }

    async fn slash(&self, signer: &str, a: &SignedVoucher, b: &SignedVoucher) -> Result<String, ChainError> {
        let mut fake = self.reach().await?;
        let banned = fake.slashed.iter().any(|(first, _)| account_of(first) == signer);
        if banned {
            return Err(ChainError::Refused("already slashed".into()));
        }
        if fake.bond == "0" {
            return Err(ChainError::Refused("nothing at stake".into()));
        }
        if let Some(why) = fake.refuse_slash {
            return Err(ChainError::Refused(why.into()));
        }
        fake.slashed.push((a.clone(), b.clone()));
        if fake.no_answer_to_slashing {
            return Err(ChainError::Unknown("timed out".into()));
        }
        Ok(format!("slash{}", fake.slashed.len()))
    }
}

/// A payment to sign. The defaults are an ordinary NearBy payment from `payer()`.
struct Pay {
    key: SigningKey,
    to: &'static str,
    memo: Option<&'static str>,
    intents: Option<Vec<Value>>,
    valid_for_hours: i64,
    nonce: [u8; 32],
}

fn payer() -> SigningKey {
    SigningKey::from_bytes(&[5; 32])
}

fn account(key: &SigningKey) -> String {
    implicit_account(key.verifying_key().as_bytes())
}

fn account_of(v: &SignedVoucher) -> String {
    serde_json::from_str::<IntentMessage>(&v.payload.message)
        .unwrap()
        .signer_id
}

impl Default for Pay {
    fn default() -> Self {
        Self {
            key: payer(),
            to: "merchant.near",
            memo: None,
            intents: None,
            valid_for_hours: 72,
            nonce: make_nonce(),
        }
    }
}

impl Pay {
    fn sign(self) -> SignedVoucher {
        let mut transfer = json!({ "intent": "transfer", "receiver_id": self.to, "tokens": { USDC_TOKEN: "2500000" } });
        if let Some(memo) = self.memo {
            transfer["memo"] = json!(memo);
        }
        let message = IntentMessage {
            signer_id: account(&self.key),
            deadline: iso(Utc::now() + Duration::hours(self.valid_for_hours)),
            intents: self.intents.unwrap_or_else(|| vec![transfer]),
        };
        sign_voucher(&self.key, &message, &self.nonce)
    }
}

fn pay() -> SignedVoucher {
    Pay::default().sign()
}

/// Two payments by `payer()` to two merchants with one sequence number: a double-spend.
fn pair() -> (SignedVoucher, SignedVoucher) {
    let numbered = |to| {
        Pay {
            to,
            memo: Some("seq:4 prev:00"),
            ..Pay::default()
        }
        .sign()
    };
    (numbered("merchant.near"), numbered("other.near"))
}

/// Uploads vouchers as a phone sends them: as JSON.
async fn settle(settler: &Settler<FakeChain>, vouchers: &[&SignedVoucher]) -> Vec<Outcome> {
    let uploaded: Vec<Value> = vouchers.iter().map(|v| json!(v)).collect();
    settler.settle(&uploaded).await
}

/// The pairs recorded so far, without what the bond contract made of them.
async fn pairs(settler: &Settler<FakeChain>) -> Vec<(SignedVoucher, SignedVoucher)> {
    settler.equivocations().await.into_iter().map(|p| (p.a, p.b)).collect()
}

/// Lets the settler's background tasks (slashing) run to completion.
async fn settle_down() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
}

fn settled(tx: Option<&str>, block: Option<u64>) -> Outcome {
    Outcome::Settled {
        tx: tx.map(String::from),
        block,
    }
}

fn invalid(reason: &str) -> Outcome {
    Outcome::Invalid { reason: reason.into() }
}

fn rejected(reason: &str) -> Outcome {
    Outcome::Rejected { reason: reason.into() }
}

#[tokio::test]
async fn settles_an_uploaded_voucher_and_says_where() {
    let chain = FakeChain::new();
    let v = pay();
    // The gateway shows the tx to the user and stops carrying the voucher.
    assert_eq!(
        settle(&Settler::new(chain.clone()), &[&v]).await,
        [settled(Some("tx1"), Some(BLOCK))]
    );
    assert_eq!(chain.state().executed, [v]);
}

// Every phone that carried a voucher uploads it. Executing it again would burn gas on a
// transaction the chain must refuse, once per extra gateway.
#[tokio::test]
async fn a_voucher_uploaded_by_several_gateways_is_executed_once() {
    let chain = FakeChain::new();
    let (settler, v) = (Settler::new(chain.clone()), pay());
    let upload = [&v];
    let (a, b) = tokio::join!(settle(&settler, &upload), settle(&settler, &upload));
    assert_eq!(
        (a, b),
        (
            vec![settled(Some("tx1"), Some(BLOCK))],
            vec![settled(Some("tx1"), Some(BLOCK))]
        )
    );
    assert_eq!(chain.state().executed.len(), 1);
}

#[tokio::test]
async fn a_voucher_already_on_chain_is_reported_settled_without_paying_gas_again() {
    // After a relayer restart, or when another relayer or the payee settled it themselves.
    let chain = FakeChain::new();
    let v = pay();
    chain
        .state()
        .used
        .insert(format!("{}:{}", account(&payer()), v.payload.nonce));
    assert_eq!(
        settle(&Settler::new(chain.clone()), &[&v]).await,
        [settled(None, Some(BLOCK))]
    );
    assert_eq!(chain.state().executed.len(), 0);
}

// The chain settles one voucher per signer and nonce. A payer who signs two on one nonce pays
// only one merchant; telling the other "settled", with the first one's transaction, would hide the theft.
#[tokio::test]
async fn a_second_voucher_on_a_spent_nonce_is_not_reported_as_settled() {
    let chain = FakeChain::new();
    let (settler, nonce) = (Settler::new(chain.clone()), make_nonce());
    let paid = Pay {
        nonce,
        ..Pay::default()
    }
    .sign();
    let cheated = Pay {
        to: "other.near",
        nonce,
        ..Pay::default()
    }
    .sign();
    assert_eq!(
        settle(&settler, &[&paid, &cheated, &paid]).await,
        [
            settled(Some("tx1"), Some(BLOCK)),
            invalid("nonce spent by another voucher"),
            settled(Some("tx1"), Some(BLOCK))
        ]
    );
    assert_eq!(chain.state().executed, [paid]);
}

// A phone compares this block with the block of a payer's attested balance to decide whether
// that balance already includes the payment. Without it the payment counts against the payer for good.
#[tokio::test]
async fn a_settled_voucher_whose_block_is_not_known_yet_is_still_settled_and_the_block_follows() {
    let chain = FakeChain::new();
    let (settler, v) = (Settler::new(chain.clone()), pay());
    chain.state().lagging = true;
    assert_eq!(settle(&settler, &[&v]).await, [settled(Some("tx1"), None)]);
    assert_eq!(
        settle(&settler, &[&v]).await,
        [settled(Some("tx1"), None)],
        "still not visible: no guess is made"
    );
    chain
        .state()
        .used
        .insert(format!("{}:{}", account(&payer()), v.payload.nonce));
    chain.state().block = BLOCK + 2;
    assert_eq!(settle(&settler, &[&v]).await, [settled(Some("tx1"), Some(BLOCK + 2))]);
    assert_eq!(chain.state().executed.len(), 1, "asking again never pays gas again");
}

#[tokio::test]
async fn losing_the_chain_right_after_settling_does_not_turn_the_settlement_into_an_error() {
    // The gas is spent and the money has moved; "error" would make every phone upload it again as unpaid.
    let chain = FakeChain::new();
    chain.state().fails_after_executing = true;
    assert_eq!(
        settle(&Settler::new(chain.clone()), &[&pay()]).await,
        [settled(Some("tx1"), None)]
    );
}

// A transaction that got no answer may still land. Sending another for the same voucher meanwhile
// pays gas for one the chain must refuse, and then reports a paid voucher as refused.
#[tokio::test]
async fn a_transaction_that_got_no_answer_is_not_sent_a_second_time_straight_away() {
    let chain = FakeChain::new();
    let (settler, v) = (Settler::new(chain.clone()), pay());
    chain.state().no_answer_to_executing = true;
    assert!(matches!(settle(&settler, &[&v]).await[..], [Outcome::Error { .. }]));
    chain.state().no_answer_to_executing = false;
    assert!(
        matches!(settle(&settler, &[&v]).await[..], [Outcome::Error { .. }]),
        "still told to ask again"
    );
    assert_eq!(chain.state().executed.len(), 1);
    // It landed after all: the phone learns so through the nonce, as with any voucher settled elsewhere.
    chain
        .state()
        .used
        .insert(format!("{}:{}", account(&payer()), v.payload.nonce));
    assert_eq!(settle(&settler, &[&v]).await, [settled(None, Some(BLOCK))]);
}

#[tokio::test]
async fn a_voucher_that_settled_before_it_expired_is_still_reported_settled_afterwards() {
    // A payee whose phone comes back online days later must learn it was paid, not see "expired".
    let chain = FakeChain::new();
    let v = Pay {
        valid_for_hours: -1,
        ..Pay::default()
    }
    .sign();
    chain
        .state()
        .used
        .insert(format!("{}:{}", account(&payer()), v.payload.nonce));
    assert_eq!(
        settle(&Settler::new(chain.clone()), &[&v]).await,
        [settled(None, Some(BLOCK))]
    );
    assert_eq!(chain.state().executed.len(), 0);
}

#[tokio::test]
async fn a_refused_voucher_uploaded_again_straight_away_is_answered_without_asking_the_chain() {
    // Every phone that carries it re-uploads it every half minute; the answer will not have changed.
    let chain = FakeChain::new();
    let (settler, broke) = (Settler::new(chain.clone()), pay());
    chain
        .state()
        .refuse
        .insert(broke.payload.nonce.clone(), "insufficient balance or overflow".into());
    let first = settle(&settler, &[&broke]).await;
    let asked = chain.state().lookups;
    assert_eq!(first, [rejected("insufficient balance or overflow")]);
    assert_eq!(settle(&settler, &[&broke]).await, first);
    assert_eq!(chain.state().lookups, asked);
}

#[tokio::test]
async fn a_voucher_the_contract_would_refuse_costs_no_gas_and_does_not_hold_up_the_others() {
    let chain = FakeChain::new();
    let (broke, fine) = (pay(), pay());
    chain
        .state()
        .refuse
        .insert(broke.payload.nonce.clone(), "insufficient balance or overflow".into());
    assert_eq!(
        settle(&Settler::new(chain.clone()), &[&broke, &fine]).await,
        // "rejected", not "invalid": the payer may top up, so the phone keeps carrying it.
        [
            rejected("insufficient balance or overflow"),
            settled(Some("tx1"), Some(BLOCK))
        ]
    );
    assert_eq!(chain.state().executed, [fine]);
}

#[tokio::test]
async fn when_the_chain_is_unreachable_the_phone_is_told_to_try_again_not_that_the_voucher_is_bad() {
    let chain = FakeChain::new();
    chain.state().down = true;
    let results = settle(&Settler::new(chain), &[&pay()]).await;
    assert!(matches!(results[..], [Outcome::Error { .. }]), "{results:?}");
}

#[tokio::test]
async fn what_is_not_a_nearby_payment_never_reaches_the_chain() {
    // The relayer pays the gas, so it settles single transfers only and nothing unverified.
    let chain = FakeChain::new();
    let mut tampered = pay();
    tampered.payload.message = tampered.payload.message.replace("merchant.near", "thief.near");
    let transfer = json!({ "intent": "transfer", "receiver_id": "a.near", "tokens": { USDC_TOKEN: "1" } });
    let signed = |intents: Vec<Value>| {
        json!(Pay {
            intents: Some(intents),
            ..Pay::default()
        }
        .sign())
    };
    let uploaded = [
        json!(tampered),
        signed(vec![transfer.clone(), transfer]),
        signed(vec![
            json!({ "intent": "ft_withdraw", "token": "usdc.near", "receiver_id": "a.near", "amount": "1" }),
        ]),
        signed(vec![
            json!({ "intent": "transfer", "receiver_id": "a.near", "tokens": { "nep141:wrap.near": "1" } }),
        ]),
        signed(vec![
            json!({ "intent": "transfer", "receiver_id": "a.near", "tokens": { USDC_TOKEN: "1", "nep141:wrap.near": "1" } }),
        ]),
        json!({ "hello": "world" }),
        Value::Null,
    ];
    let results = Settler::new(chain.clone()).settle(&uploaded).await;
    let reasons = [
        "signature",
        "intents",
        "intents",
        "intents",
        "intents",
        "malformed",
        "malformed",
    ];
    assert_eq!(results, reasons.map(invalid));
    assert_eq!(chain.state().executed.len(), 0);
}

#[tokio::test]
async fn a_field_the_contract_would_hash_is_not_passed_on() {
    // intents.near hashes payload.callback_url if present; the signature was made without it.
    let chain = FakeChain::new();
    let v = pay();
    let mut padded = json!(v);
    padded["payload"]["callback_url"] = json!("x");
    padded["extra"] = json!(1);
    Settler::new(chain.clone()).settle(&[padded]).await;
    assert_eq!(chain.state().executed, [v]);
}

// Layer 2 of the double-spend model: two vouchers with one sequence number are a self-contained
// proof that the payer cheated, and the relayer is where both halves finally meet.
#[tokio::test]
async fn two_vouchers_with_the_same_sequence_number_are_kept_as_proof_and_both_still_go_to_the_chain() {
    let chain = FakeChain::new();
    let settler = Settler::new(chain.clone());
    let first = Pay {
        memo: Some("req:aa seq:4 prev:00"),
        ..Pay::default()
    }
    .sign();
    let second = Pay {
        to: "other.near",
        memo: Some("seq:4 prev:00"),
        ..Pay::default()
    }
    .sign();
    settle(
        &settler,
        &[
            &first,
            &Pay {
                memo: Some("seq:5 prev:00"),
                ..Pay::default()
            }
            .sign(),
        ],
    )
    .await;
    settle(&settler, &[&second, &second, &first]).await;
    assert_eq!(pairs(&settler).await, [(first, second)]);
    assert_eq!(
        chain.state().executed.len(),
        3,
        "the chain decides which of the pair the balance covers"
    );
}

// Layer 3 of the double-spend model: the proof costs the cheat their bond, without anyone having to
// collect pairs from the relayer and submit them by hand.
#[tokio::test]
async fn a_pair_goes_to_the_bond_contract_and_the_slashing_transaction_is_published() {
    let chain = FakeChain::new();
    let settler = Settler::new(chain.clone());
    let (first, second) = pair();
    settle(&settler, &[&first, &second]).await;
    settle_down().await;
    assert_eq!(chain.state().slashed, [(first, second)]);
    assert_eq!(settler.equivocations().await[0].tx.as_deref(), Some("slash1"));
}

// The relayer could not reach the chain; nothing is known. The pair must not be lost, and the
// next gateway to carry the voucher gives it another go.
#[tokio::test]
async fn a_slashing_lost_to_an_outage_is_sent_again_with_the_next_upload() {
    let chain = FakeChain::new();
    let settler = Settler::new(chain.clone());
    let (first, second) = pair();
    settle(&settler, &[&first]).await;
    chain.state().down = true;
    settle(&settler, &[&second]).await;
    settle_down().await;
    let proof = &settler.equivocations().await[0];
    assert_eq!((proof.tx.as_deref(), proof.refusal.as_deref()), (None, None));
    chain.state().down = false;
    settle(&settler, &[&second]).await;
    settle_down().await;
    assert_eq!(settler.equivocations().await[0].tx.as_deref(), Some("slash1"));
    assert_eq!(chain.state().slashed.len(), 1);
}

// The relayer believed the pair was proof and the contract did not: a bug in one of them, or an
// attack on the check. Either way the operator must see it, not lose it.
#[tokio::test]
async fn a_pair_the_bond_contract_turns_down_is_kept_with_its_reason() {
    let chain = FakeChain::new();
    chain.state().refuse_slash = Some("different sequence numbers");
    let settler = Settler::new(chain.clone());
    let (first, second) = pair();
    settle(&settler, &[&first, &second]).await;
    settle_down().await;
    let proof = &settler.equivocations().await[0];
    assert_eq!(
        (proof.tx.as_deref(), proof.refusal.as_deref()),
        (None, Some("different sequence numbers"))
    );
}

// The slashing landed but its answer was lost. Sending it again would burn gas on a transaction the
// contract must refuse, and record that refusal as if the key had never been slashed.
#[tokio::test]
async fn a_slashing_whose_answer_was_lost_is_recognised_rather_than_sent_again() {
    let chain = FakeChain::new();
    chain.state().no_answer_to_slashing = true;
    let settler = Settler::new(chain.clone());
    let (first, second) = pair();
    settle(&settler, &[&first, &second]).await;
    settle_down().await;
    chain.state().no_answer_to_slashing = false;
    settle(&settler, &[&second]).await;
    settle_down().await;
    let proof = &settler.equivocations().await[0];
    assert_eq!(
        (proof.tx.as_deref(), proof.refusal.as_deref()),
        (None, Some("already slashed"))
    );
    assert_eq!(chain.state().slashed.len(), 1, "one transaction, not two");
}

// Pairs are free to make with a throwaway key; a transaction for each would cost the relayer gas.
#[tokio::test]
async fn a_pair_from_a_key_with_nothing_at_stake_is_kept_but_not_sent() {
    let chain = FakeChain::new();
    chain.state().bond = "0";
    let settler = Settler::new(chain.clone());
    let (first, second) = pair();
    settle(&settler, &[&first, &second]).await;
    settle_down().await;
    let proof = &settler.equivocations().await[0];
    assert_eq!(
        (proof.tx.as_deref(), proof.refusal.as_deref()),
        (None, Some("nothing at stake"))
    );
    assert!(chain.state().slashed.is_empty());
}

#[tokio::test]
async fn an_expired_voucher_is_not_settled_but_still_counts_as_half_of_a_proof() {
    // The cheated merchant's voucher often reaches the relayer late. The payer's two signatures
    // prove the double-spend whether or not the voucher could still settle.
    let chain = FakeChain::new();
    let settler = Settler::new(chain.clone());
    let first = Pay {
        memo: Some("seq:4 prev:00"),
        ..Pay::default()
    }
    .sign();
    let late = Pay {
        to: "other.near",
        memo: Some("seq:4 prev:00"),
        valid_for_hours: -1,
        ..Pay::default()
    }
    .sign();
    assert_eq!(settle(&settler, &[&first, &late]).await[1], invalid("expired"));
    assert_eq!(pairs(&settler).await, [(first.clone(), late)]);
    assert_eq!(chain.state().executed, [first]);
}

#[tokio::test]
async fn a_long_upload_does_not_make_a_short_one_wait_for_all_of_it() {
    // One phone carrying a festival's worth of vouchers must not delay everyone else's payments.
    let chain = FakeChain::new();
    let settler = Settler::new(chain.clone());
    let (long, short) = ([pay(), pay(), pay(), pay()], pay());
    let (long_upload, short_upload) = (long.each_ref(), [&short]);
    tokio::join!(settle(&settler, &long_upload), settle(&settler, &short_upload));
    let served = chain.state().executed.iter().position(|v| *v == short).unwrap();
    assert!(served < 3, "the short upload was served at position {served}");
}

#[tokio::test]
async fn a_pair_that_reuses_the_nonce_as_well_as_the_sequence_number_is_still_proof() {
    let settler = Settler::new(FakeChain::new());
    let nonce = make_nonce();
    let first = Pay {
        memo: Some("seq:4 prev:00"),
        nonce,
        ..Pay::default()
    }
    .sign();
    let second = Pay {
        to: "other.near",
        memo: Some("seq:4 prev:00"),
        nonce,
        ..Pay::default()
    }
    .sign();
    settle(&settler, &[&first, &second]).await;
    assert_eq!(pairs(&settler).await, [(first, second)]);
}

#[tokio::test]
async fn someone_elses_pair_cannot_make_a_real_proof_look_already_recorded() {
    // Nonces are public once a voucher is gossiped; a cheat could plant a pair that reuses theirs.
    let settler = Settler::new(FakeChain::new());
    let (nonce, throwaway) = (make_nonce(), SigningKey::from_bytes(&[6; 32]));
    let planted = |nonce| {
        Pay {
            key: throwaway.clone(),
            memo: Some("seq:1 prev:00"),
            nonce,
            ..Pay::default()
        }
        .sign()
    };
    settle(&settler, &[&planted(make_nonce()), &planted(nonce)]).await;
    let first = Pay {
        memo: Some("seq:4 prev:00"),
        ..Pay::default()
    }
    .sign();
    let second = Pay {
        to: "other.near",
        memo: Some("seq:4 prev:00"),
        nonce,
        ..Pay::default()
    }
    .sign();
    settle(&settler, &[&first, &second]).await;
    assert_eq!(pairs(&settler).await[1], (first, second));
}

#[tokio::test]
async fn the_same_voucher_respelled_is_not_a_second_voucher() {
    // Whoever carries a voucher can rewrite its text. If that made a pair, any relay could frame an honest payer.
    let settler = Settler::new(FakeChain::new());
    let v = Pay {
        memo: Some("seq:4 prev:00"),
        ..Pay::default()
    }
    .sign();
    let mut respelled = v.clone();
    respelled.signature = v.signature.replace("ed25519:", "");
    assert_eq!(settle(&settler, &[&v, &respelled]).await[1], invalid("malformed"));
    assert_eq!(pairs(&settler).await, []);
}

#[tokio::test]
async fn the_same_sequence_number_from_two_different_payers_is_not_a_double_spend() {
    let settler = Settler::new(FakeChain::new());
    let other = Pay {
        key: SigningKey::from_bytes(&[6; 32]),
        memo: Some("seq:1 prev:00"),
        ..Pay::default()
    }
    .sign();
    settle(
        &settler,
        &[
            &Pay {
                memo: Some("seq:1 prev:00"),
                ..Pay::default()
            }
            .sign(),
            &other,
        ],
    )
    .await;
    assert_eq!(pairs(&settler).await, []);
}

// ---- over HTTP

fn attestation_key() -> SigningKey {
    SigningKey::from_bytes(&[8; 32])
}

fn now() -> DateTime<Utc> {
    AT.parse().unwrap()
}

/// One request to a relayer on `chain`: the status and the JSON it answered.
async fn request(chain: &Arc<FakeChain>, method: &str, path: &str, body: Option<Value>) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    let request = request
        .body(body.map_or(Body::empty(), |json| Body::from(json.to_string())))
        .unwrap();
    let response = router(chain.clone(), attestation_key(), now)
        .oneshot(request)
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

#[tokio::test]
async fn a_gateway_uploads_its_outbox_over_http_and_gets_one_result_per_voucher() {
    let chain = FakeChain::new();
    let (status, body) = request(&chain, "POST", "/vouchers", Some(json!({ "vouchers": [pay(), {}] }))).await;
    assert_eq!(status, StatusCode::OK);
    // The exact JSON the app reads: app/lib/gateway.dart looks for "status", "tx" and "block".
    assert_eq!(
        body,
        json!({ "results": [{ "status": "settled", "tx": "tx1", "block": BLOCK }, { "status": "invalid", "reason": "malformed" }] })
    );
}

// Phones upload when they briefly have a signal, and often lose it before the answer. The gas is
// spent either way; what must not happen is a transaction sent and nothing remembered about it.
#[tokio::test]
async fn an_upload_is_settled_even_if_the_phone_hangs_up_before_the_answer() {
    let chain = FakeChain::new();
    let body = json!({ "vouchers": [pay(), pay()] }).to_string();
    let upload = Request::post("/vouchers")
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap();
    let mut answer = Box::pin(router(chain.clone(), attestation_key(), now).oneshot(upload));
    tokio::select! {
        biased;
        _ = &mut answer => panic!("answered before the chain was even asked"),
        _ = tokio::task::yield_now() => {}
    }
    drop(answer);
    for _ in 0..100 {
        tokio::task::yield_now().await;
    }
    assert_eq!(chain.state().executed.len(), 2);
}

#[tokio::test]
async fn an_upload_that_is_not_a_list_of_vouchers_is_turned_away() {
    let chain = FakeChain::new();
    let too_many = json!({ "vouchers": vec![json!({}); 501] });
    for body in [
        Some(json!({ "nope": 1 })),
        Some(json!({ "vouchers": "all of them" })),
        Some(json!([1])),
        Some(too_many),
        None,
    ] {
        assert_eq!(
            request(&chain, "POST", "/vouchers", body).await.0,
            StatusCode::BAD_REQUEST
        );
    }
}

// A payee with no network hands over goods on the strength of this statement, so it must be
// the chain's number, signed by the key the app pins, and bound to the account, time and block.
#[tokio::test]
async fn an_attestation_is_the_chain_balance_signed_by_the_relayers_published_key() {
    let chain = FakeChain::new();
    let signer = account(&payer());
    let (_, signed) = request(&chain, "GET", &format!("/attestation/{signer}"), None).await;
    let payload = signed["payload"].as_str().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(payload).unwrap(),
        json!({ "account": signer, "token": USDC_TOKEN, "balance": "25000000", "bond": "5000000000000000000000000", "as_of": AT, "block": BLOCK })
    );
    // A payee reads the bond off the attestation: with none, there is nothing to lose by cheating.
    chain.state().bond = "0";
    let (_, unbonded) = request(&chain, "GET", &format!("/attestation/{signer}"), None).await;
    let unbonded: Value = serde_json::from_str(unbonded["payload"].as_str().unwrap()).unwrap();
    assert_eq!(unbonded["bond"], "0");
    let (_, about) = request(&chain, "GET", "/", None).await;
    assert_eq!(
        about["attestation_key"],
        tag(attestation_key().verifying_key().as_bytes())
    );
    let signature = Signature::from_bytes(&untag(signed["signature"].as_str().unwrap()).unwrap());
    let verifies = |payload: &str| {
        attestation_key()
            .verifying_key()
            .verify(format!("{ATTESTATION_DOMAIN}{payload}").as_bytes(), &signature)
            .is_ok()
    };
    assert!(verifies(payload));
    assert!(!verifies(&payload.replace("25000000", "95000000")));
}

#[tokio::test]
async fn no_attestation_for_something_that_is_not_an_offline_account_or_when_the_balance_is_unknown() {
    let chain = FakeChain::new();
    assert_eq!(
        request(&chain, "GET", "/attestation/merchant.near", None).await.0,
        StatusCode::BAD_REQUEST
    );
    chain.state().down = true;
    assert_eq!(
        request(&chain, "GET", &format!("/attestation/{}", account(&payer())), None)
            .await
            .0,
        StatusCode::INTERNAL_SERVER_ERROR
    );
}

#[tokio::test]
async fn proofs_of_double_spending_are_published_as_pairs_of_vouchers() {
    // Both vouchers exactly as signed, so anyone can check the proof, and the slashing transaction.
    let chain = FakeChain::new();
    let (first, second) = pair();
    let app = router(chain.clone(), attestation_key(), now);
    let upload = Request::post("/vouchers")
        .header("content-type", "application/json")
        .body(Body::from(json!({ "vouchers": [first, second] }).to_string()))
        .unwrap();
    app.clone().oneshot(upload).await.unwrap();
    settle_down().await;
    let response = app
        .oneshot(Request::get("/equivocations").body(Body::empty()).unwrap())
        .await
        .unwrap();
    let published: Value = serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(published, json!([{ "a": first, "b": second, "tx": "slash1" }]));
}
