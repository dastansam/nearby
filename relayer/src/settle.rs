//! Settling uploaded vouchers, and noticing when a payer has signed two for one sequence number.
use crate::chain::{Chain, ChainError};
use crate::journal::{Journal, Record};
use crate::log;
use crate::voucher::{transfer, verify_voucher, Checked, SignedVoucher, USDC_TOKEN};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
// tokio's clock, so tests can move time on; std's otherwise.
use tokio::time::Instant;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "status", rename_all = "lowercase")]
pub enum Outcome {
    /// On chain. `tx` is missing when someone else settled it or this relayer restarted since.
    /// `block` is a height by which the chain showed it settled: an attestation read at that height
    /// or later already reflects the payment. It is missing only until the RPC node shows the
    /// transaction, so a phone should ask again.
    Settled {
        #[serde(skip_serializing_if = "Option::is_none")]
        tx: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        block: Option<u64>,
    },
    /// Not a voucher this relayer settles, or one that can no longer settle. It never will: stop sending it.
    Invalid { reason: String },
    /// The contract refuses it today (say, the payer's balance is short). It may settle later.
    Rejected { reason: String },
    /// The relayer could not reach the chain. Nothing is known about the voucher: send it again.
    Error { reason: String },
}

fn invalid(reason: &str) -> Outcome {
    Outcome::Invalid { reason: reason.into() }
}

/// What is known about a spent nonce. No signature means the chain says the nonce is spent and we
/// do not know by which voucher.
#[derive(Clone, Default)]
struct Spent {
    signature: Option<String>,
    tx: Option<String>,
    block: Option<u64>,
}

impl Spent {
    fn settled(&self) -> Outcome {
        Outcome::Settled {
            tx: self.tx.clone(),
            block: self.block,
        }
    }
}

/// How long a refusal is repeated without asking the chain again: every phone carrying the voucher re-uploads it.
const REFUSAL_TTL: Duration = Duration::from_secs(60);

/// How long after a transaction went out with no answer before another is sent for the same voucher.
/// The first may still land; a second one sent meanwhile fails on chain and its gas is wasted.
const IN_FLIGHT: Duration = Duration::from_secs(120);

/// How long a pair whose slashing ran out of gas rests before it is sent again.
const PROOF_RETRY: Duration = Duration::from_secs(60 * 60);

/// How often pairs not yet slashed are looked at again. Nothing else would: a voucher that has
/// settled is no longer uploaded, so its pair cannot wait for an upload to be retried.
const SWEEP_EVERY: Duration = Duration::from_secs(60);

/// Pairs handed to the chain per sweep. They are free to make, so it is not asked about thousands at once.
const SWEEP_BATCH: usize = 20;

/// Proofs kept. They are free to make for anyone with a key.
const MAX_PROOFS: usize = 10_000;

/// Two vouchers one payer signed with the same sequence number, and what the bond contract made of
/// them. Until `tx` is set the pair goes to the contract again, found by the sweep: after the
/// in-flight time when nothing is known, after a rest when it ran out of gas, never when the
/// contract judged the pair.
#[derive(Serialize, Clone, Debug)]
pub struct Proof {
    #[serde(skip)]
    signer: String,
    pub a: SignedVoucher,
    pub b: SignedVoucher,
    /// The slashing transaction, once it has run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx: Option<String>,
    /// Why the pair was not slashed the last time it was sent: nothing at stake, the contract found
    /// it no proof, or the slashing ran out of gas.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
    /// Not before this is the pair sent again: a slashing may be on its way, or was refused. A
    /// deadline, not a flag, so a slashing whose task never reports back does not hold it for ever.
    #[serde(skip)]
    retry_after: Option<Instant>,
    /// How many times the pair has been sent. An attempt's answer counts only while it is the latest.
    #[serde(skip)]
    attempt: u64,
}

impl Proof {
    fn new(signer: String, a: SignedVoucher, b: SignedVoucher) -> Self {
        Self {
            signer,
            a,
            b,
            tx: None,
            refusal: None,
            retry_after: None,
            attempt: 0,
        }
    }

    /// Nothing more will be asked of the chain about it: slashed, or judged by the contract.
    fn closed(&self) -> bool {
        self.tx.is_some() || self.refusal.as_deref().is_some_and(|why| !retryable(why))
    }

    /// Whether the pair should go to the bond contract now: not closed, and not on its way.
    fn due(&self, now: Instant) -> bool {
        !self.closed() && self.retry_after.is_none_or(|after| after <= now)
    }

    /// Marks the pair as on its way and returns it, if it is due.
    fn start_if_due(&mut self, now: Instant) -> Option<Proof> {
        self.due(now).then(|| {
            self.retry_after = Some(now + IN_FLIGHT);
            self.attempt += 1;
            self.clone()
        })
    }
}

/// Whether a refusal may pass: only a slashing that ran out of gas. The rest are the contract's
/// judgement of the pair, or of the key ("nothing at stake": payees demand a bond, so a payer
/// without one was never trusted offline), and asking again changes nothing.
fn retryable(refusal: &str) -> bool {
    refusal.contains("prepaid gas")
}

/// A map that forgets its oldest entry once full. These are fed by anyone who can sign.
struct Remembered<V> {
    entries: HashMap<String, V>,
    oldest_first: VecDeque<String>,
}

impl<V> Remembered<V> {
    const LIMIT: usize = 100_000;

    fn new() -> Self {
        Self {
            entries: HashMap::new(),
            oldest_first: VecDeque::new(),
        }
    }

    fn insert(&mut self, key: String, value: V) {
        if self.entries.insert(key.clone(), value).is_some() {
            return;
        }
        self.oldest_first.push_back(key);
        if self.oldest_first.len() > Self::LIMIT {
            let oldest = self.oldest_first.pop_front().expect("just pushed");
            self.entries.remove(&oldest);
        }
    }
}

struct State {
    /// "signer:nonce" -> the voucher that spent that nonce and its tx, when this relayer sent it.
    done: HashMap<String, Spent>,
    /// By signature: the contract's reason, and until when it is repeated unasked.
    refused: Remembered<(String, Instant)>,
    /// "signer:nonce" -> until when a transaction this relayer sent may still be on its way.
    in_flight: Remembered<Instant>,
    /// "signer:seq" -> the first voucher seen with that sequence number.
    by_seq: Remembered<SignedVoucher>,
    /// In the order found. A pair is known by the signature of its second voucher.
    equivocations: Vec<Proof>,
    /// Where `by_seq` and `equivocations` are kept across restarts, if anywhere.
    journal: Option<Journal>,
}

impl State {
    fn new() -> Self {
        Self {
            done: HashMap::new(),
            refused: Remembered::new(),
            in_flight: Remembered::new(),
            by_seq: Remembered::new(),
            equivocations: Vec::new(),
            journal: None,
        }
    }

    /// The one place `by_seq` and `equivocations` change, whether for an upload or for what an
    /// earlier run wrote down, so memory and journal cannot disagree. Attempts are not remembered: a
    /// pair not slashed yet is due at once, and the chain says "already slashed" if it was after all.
    fn apply(&mut self, record: Record) {
        match record {
            Record::Seen { slot, voucher } => self.by_seq.insert(slot, voucher),
            Record::Pair { signer, a, b } => {
                // Pairs cost nothing to make, so the list must not fill up with junk a real
                // double-spender then cannot get into: a full list drops its oldest closed pair.
                if self.equivocations.len() >= MAX_PROOFS {
                    if let Some(at) = self.equivocations.iter().position(Proof::closed) {
                        self.equivocations.remove(at);
                    }
                }
                if self.equivocations.len() < MAX_PROOFS {
                    self.equivocations.push(Proof::new(signer, a, b));
                }
            }
            Record::Answer { b, tx, refusal } => {
                if let Some(proof) = self.equivocations.iter_mut().rfind(|p| p.b.signature == b) {
                    if tx.is_some() {
                        proof.retry_after = None;
                    }
                    (proof.tx, proof.refusal) = (tx, refusal);
                }
            }
        }
    }

    /// Writes `record` to the journal, if there is one, and applies it.
    fn commit(&mut self, record: Record) {
        if let Some(journal) = &mut self.journal {
            journal.append(&record);
        }
        self.apply(record);
    }
}

/// A voucher this relayer settles: validly signed, and one USDC transfer.
struct Payment {
    v: SignedVoucher,
    signer: String,
    /// The payer's sequence number for it, as written in the memo.
    seq: Option<String>,
    expired: bool,
}

/// Everything that can be said about an upload without the chain. The error is why it is not a payment.
fn admit(input: &Value) -> Result<Payment, &'static str> {
    // Only the fields the contract hashes go on: an extra one would change what it verifies.
    let v = SignedVoucher::deserialize(input).map_err(|_| "malformed")?;
    let Checked { message, expired } = verify_voucher(&v, Utc::now())?;
    // The relayer pays gas for NearBy payments (one USDC transfer), not for whatever else someone signs.
    let payment = transfer(&message)
        .filter(|t| t.tokens.len() == 1 && t.tokens.contains_key(USDC_TOKEN))
        .ok_or("intents")?;
    Ok(Payment {
        seq: payment.sequence().map(String::from),
        signer: message.signer_id,
        expired,
        v,
    })
}

pub struct Settler<C> {
    chain: Arc<C>,
    state: Arc<Mutex<State>>,
}

impl<C: Chain> Settler<C> {
    pub fn new(chain: Arc<C>) -> Self {
        Self {
            chain,
            state: Arc::new(Mutex::new(State::new())),
        }
    }

    /// Like [`Settler::new`], remembering sequence numbers and double-spends in the journal at
    /// `path`: what an earlier run wrote there is taken back in first.
    pub fn with_journal(chain: Arc<C>, path: &Path) -> std::io::Result<Self> {
        let (journal, records) = Journal::open(path)?;
        let mut state = State::new();
        for record in records {
            state.apply(record);
        }
        log(format!(
            "journal {}: {} sequence numbers, {} double-spends, {} not slashed yet",
            path.display(),
            state.by_seq.entries.len(),
            state.equivocations.len(),
            state.equivocations.iter().filter(|p| p.tx.is_none()).count()
        ));
        state.journal = Some(journal);
        Ok(Self {
            chain,
            state: Arc::new(Mutex::new(state)),
        })
    }

    /// Hands every pair that is due to the bond contract, a few at a time.
    pub async fn sweep(&self) {
        let due: Vec<Proof> = {
            let mut state = self.state.lock().await;
            let now = Instant::now();
            state
                .equivocations
                .iter_mut()
                .filter_map(|p| p.start_if_due(now))
                .take(SWEEP_BATCH)
                .collect()
        };
        for proof in due {
            self.slash(proof);
        }
    }

    /// Sweeps now and then for as long as the relayer runs.
    pub fn keep_sweeping(&self) {
        let this = Self {
            chain: Arc::clone(&self.chain),
            state: Arc::clone(&self.state),
        };
        tokio::spawn(async move {
            let mut every = tokio::time::interval(SWEEP_EVERY);
            every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                every.tick().await;
                this.sweep().await;
            }
        });
    }

    /// One result per input, in order. Across all uploads, vouchers are handled one at a time: two
    /// gateways often carry the same voucher, and the relayer's access key signs one transaction at
    /// a time. The lock is taken per voucher and granted in the order asked for, so uploads take
    /// turns voucher by voucher and a long one does not hold up a short one.
    pub async fn settle(&self, vouchers: &[Value]) -> Vec<Outcome> {
        let mut results = Vec::with_capacity(vouchers.len());
        for input in vouchers {
            // Checked before queueing: what is not a payment should not wait behind a transaction to be told so.
            results.push(match admit(input) {
                Ok(payment) => self.one(&mut *self.state.lock().await, payment).await,
                Err(reason) => invalid(reason),
            });
        }
        results
    }

    /// Pairs of vouchers one payer signed with the same sequence number: proof of double-spending.
    pub async fn equivocations(&self) -> Vec<Proof> {
        self.state.lock().await.equivocations.clone()
    }

    /// Hands a pair to the bond contract, in a task of its own: the vouchers still go to
    /// intents.near meanwhile. The key signs one transaction at a time, so a settlement waits for
    /// a slashing only while its transaction is being sent, and the two cannot race for the nonce.
    fn slash(&self, proof: Proof) {
        let (chain, state) = (Arc::clone(&self.chain), Arc::clone(&self.state));
        tokio::spawn(async move {
            let result = chain.slash(&proof.signer, &proof.a, &proof.b).await;
            let mut state = state.lock().await;
            let Some(live) = state
                .equivocations
                .iter_mut()
                .rfind(|p| p.b.signature == proof.b.signature)
            else {
                return;
            };
            let signer = &proof.signer;
            let answer = |tx, refusal| Record::Answer {
                b: proof.b.signature.clone(),
                tx,
                refusal,
            };
            let record = match result {
                Ok(tx) => {
                    log(format!("slashed {signer}: tx {tx}"));
                    Some(answer(Some(tx), None))
                }
                // An attempt given up on, back late: it says nothing about the one now on its way,
                // or about a slashing that has landed since.
                Err(_) if live.attempt != proof.attempt => None,
                Err(ChainError::Refused(why)) => {
                    log(format!("slashing {signer} refused: {why}"));
                    if retryable(&why) {
                        live.retry_after = Some(Instant::now() + PROOF_RETRY);
                    }
                    Some(answer(None, Some(why)))
                }
                // Nothing is known, and the transaction may still land: the pair goes again once
                // the in-flight time is up, as a settlement would.
                Err(ChainError::Unknown(why)) => {
                    log(format!("slashing {signer} got no answer: {why}"));
                    None
                }
            };
            if let Some(record) = record {
                state.commit(record);
            }
        });
    }

    async fn one(&self, state: &mut State, payment: Payment) -> Outcome {
        let Payment {
            v,
            signer,
            seq,
            expired,
        } = payment;
        if let Some(proof) = seq.and_then(|seq| state.note_sequence(&signer, &seq, &v)) {
            self.slash(proof);
        }
        match self.ask_chain(state, &v, &signer, expired).await {
            Ok(outcome) => outcome,
            Err(ChainError::Unknown(reason)) => {
                log(format!("could not settle for {signer}: {reason}"));
                Outcome::Error { reason }
            }
            Err(ChainError::Refused(reason)) => {
                log(format!("turned down for {signer}: {reason}"));
                state
                    .refused
                    .insert(v.signature, (reason.clone(), Instant::now() + REFUSAL_TTL));
                Outcome::Rejected { reason }
            }
        }
    }

    async fn ask_chain(
        &self,
        state: &mut State,
        v: &SignedVoucher,
        signer: &str,
        expired: bool,
    ) -> Result<Outcome, ChainError> {
        let slot = format!("{signer}:{}", v.payload.nonce);
        let spent = state.done.get(&slot).cloned();
        if let Some(spent) = &spent {
            // A nonce settles one voucher. Another voucher on the same nonce did not get paid by that
            // transaction, so it must not be told "settled".
            if spent.signature.as_ref().is_some_and(|by| *by != v.signature) {
                return Ok(invalid("nonce spent by another voucher"));
            }
            if spent.block.is_some() {
                return Ok(spent.settled());
            }
        } else if let Some((reason, until)) = state.refused.entries.get(&v.signature) {
            if *until > Instant::now() {
                return Ok(Outcome::Rejected { reason: reason.clone() });
            }
        }
        let seen = self.chain.is_nonce_used(signer, &v.payload.nonce).await?;
        if seen.value {
            let known = Spent {
                block: Some(seen.block),
                ..spent.unwrap_or_default()
            };
            state.done.insert(slot, known.clone());
            return Ok(known.settled());
        }
        if let Some(sent) = spent {
            return Ok(sent.settled()); // we sent it; the node asked just now has not caught up
        }
        if expired {
            return Ok(invalid("expired"));
        }
        if state
            .in_flight
            .entries
            .get(&slot)
            .is_some_and(|until| *until > Instant::now())
        {
            return Err(ChainError::Unknown(
                "a transaction for this voucher may still be on its way".into(),
            ));
        }
        self.chain.simulate(v).await?; // free; execute costs gas even when it fails
        let tx = match self.chain.execute(v).await {
            Ok(tx) => tx,
            Err(e) => {
                // No answer is not "not sent": the transaction may have gone out and land later.
                if matches!(e, ChainError::Unknown(_)) {
                    state.in_flight.insert(slot, Instant::now() + IN_FLIGHT);
                }
                return Err(e);
            }
        };
        log(format!("settled for {signer}: tx {tx}"));
        let mut sent = Spent {
            signature: Some(v.signature.clone()),
            tx: Some(tx),
            block: None,
        };
        state.done.insert(slot.clone(), sent.clone());
        // Recorded first, then the block is asked for: failing to learn it, or a node that does not
        // show the transaction yet, must not turn a settled voucher into an error. The next upload fills it in.
        if let Ok(after) = self.chain.is_nonce_used(signer, &v.payload.nonce).await {
            if after.value {
                sent.block = Some(after.block);
                state.done.insert(slot, sent.clone());
            }
        }
        Ok(sent.settled())
    }
}

impl State {
    /// Both vouchers of a pair still go to the chain, which settles whichever the balance allows.
    /// Returns the pair to hand to the bond contract, when there is one it has not answered about.
    fn note_sequence(&mut self, signer: &str, seq: &str, v: &SignedVoucher) -> Option<Proof> {
        let slot = format!("{signer}:{seq}");
        let first = match self.by_seq.entries.get(&slot) {
            None => {
                self.commit(Record::Seen {
                    slot,
                    voucher: v.clone(),
                });
                return None;
            }
            // Compared by what was signed: the contract hashes the message, so a second signature
            // over the same one is the same voucher, not a pair (two different vouchers may even
            // share a nonce). Only the payer can sign, so nobody else can make a real pair look
            // already recorded.
            Some(first) if first.payload == v.payload => return None,
            Some(first) => first.clone(),
        };
        let known = |state: &Self| state.equivocations.iter().rposition(|p| p.b.payload == v.payload);
        let at = match known(self) {
            Some(at) => at,
            None => {
                log(format!(
                    "double-spend by {signer}: two vouchers with sequence number {seq}"
                ));
                self.commit(Record::Pair {
                    signer: signer.to_owned(),
                    a: first,
                    b: v.clone(),
                });
                known(self)? // not there if the list is full of pairs still waiting on the chain
            }
        };
        self.equivocations[at].start_if_due(Instant::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn voucher(n: usize) -> SignedVoucher {
        serde_json::from_value(json!({
            "standard": "nep413",
            "payload": { "message": "{}", "nonce": "AAAA", "recipient": "intents.near" },
            "public_key": "ed25519:k",
            "signature": format!("ed25519:{n}"),
        }))
        .unwrap()
    }

    fn pair(signer: &str, n: usize) -> Record {
        Record::Pair {
            signer: signer.into(),
            a: voucher(2 * n),
            b: voucher(2 * n + 1),
        }
    }

    // Anyone with a key can mint pairs for free, and the journal brings them back on every restart.
    // If they could fill the list, a real double-spender could never be recorded.
    #[test]
    fn a_full_list_makes_room_for_a_new_pair_by_dropping_one_already_judged() {
        let mut state = State::new();
        for n in 0..MAX_PROOFS {
            state.apply(pair("junk", n));
        }
        state.apply(pair("real", MAX_PROOFS));
        assert!(
            state.equivocations.iter().all(|p| p.signer == "junk"),
            "no room while every pair still waits on the chain"
        );

        let judged = voucher(1).signature; // the oldest pair's second voucher
        state.apply(Record::Answer {
            b: judged.clone(),
            tx: None,
            refusal: Some("nothing at stake".into()),
        });
        state.apply(pair("real", MAX_PROOFS));
        assert_eq!(state.equivocations.len(), MAX_PROOFS);
        assert!(state.equivocations.iter().any(|p| p.signer == "real"));
        assert!(state.equivocations.iter().all(|p| p.b.signature != judged));
    }
}
