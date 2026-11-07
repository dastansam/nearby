//! Settling uploaded vouchers, and noticing when a payer has signed two for one sequence number.
use crate::chain::{Chain, ChainError};
use crate::voucher::{transfer, verify_voucher, Checked, SignedVoucher, USDC_TOKEN};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

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

/// Proofs kept. They are free to make for anyone with a key.
const MAX_PROOFS: usize = 10_000;

/// Two vouchers one payer signed with the same sequence number, and what the bond contract made of
/// them. Neither `tx` nor `refusal` means the contract has not answered yet: the pair goes to it
/// again the next time `b` is uploaded.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Proof {
    pub a: SignedVoucher,
    pub b: SignedVoucher,
    /// The slashing transaction, once it has run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx: Option<String>,
    /// Why the pair was not slashed, when the chain gave a final answer: nothing at stake, or the
    /// contract found it no proof.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
    /// A slashing is on its way to the chain.
    #[serde(skip)]
    pending: bool,
}

impl Proof {
    fn answered(&self) -> bool {
        self.tx.is_some() || self.refusal.is_some()
    }
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
        let state = State {
            done: HashMap::new(),
            refused: Remembered::new(),
            in_flight: Remembered::new(),
            by_seq: Remembered::new(),
            equivocations: Vec::new(),
        };
        Self {
            chain,
            state: Arc::new(Mutex::new(state)),
        }
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
    /// intents.near meanwhile, and a slow slashing holds up nobody's settlement.
    fn slash(&self, a: SignedVoucher, b: SignedVoucher) {
        let (chain, state) = (Arc::clone(&self.chain), Arc::clone(&self.state));
        tokio::spawn(async move {
            let result = chain.slash(&a, &b).await;
            let mut state = state.lock().await;
            let Some(proof) = state.equivocations.iter_mut().rfind(|p| p.b.signature == b.signature) else {
                return;
            };
            proof.pending = false;
            match result {
                Ok(tx) => proof.tx = Some(tx),
                Err(ChainError::Refused(why)) => proof.refusal = Some(why),
                // Nothing is known: the next upload of the voucher sends the pair again.
                Err(ChainError::Unknown(_)) => {}
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
        if let Some((a, b)) = seq.and_then(|seq| state.note_sequence(&signer, &seq, &v)) {
            self.slash(a, b);
        }
        match self.ask_chain(state, &v, &signer, expired).await {
            Ok(outcome) => outcome,
            Err(ChainError::Unknown(reason)) => Outcome::Error { reason },
            Err(ChainError::Refused(reason)) => {
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
    fn note_sequence(&mut self, signer: &str, seq: &str, v: &SignedVoucher) -> Option<(SignedVoucher, SignedVoucher)> {
        let slot = format!("{signer}:{seq}");
        let Some(first) = self.by_seq.entries.get(&slot) else {
            self.by_seq.insert(slot, v.clone());
            return None;
        };
        // Compared by signature: two different vouchers may even share a nonce, and only the payer
        // can produce a signature, so nobody else can make a real pair look already recorded.
        if first.signature == v.signature {
            return None;
        }
        let known = self.equivocations.iter().rposition(|p| p.b.signature == v.signature);
        let proof = match known {
            Some(at) => &mut self.equivocations[at],
            None if self.equivocations.len() < MAX_PROOFS => {
                self.equivocations.push(Proof {
                    a: first.clone(),
                    b: v.clone(),
                    tx: None,
                    refusal: None,
                    pending: false,
                });
                self.equivocations.last_mut().expect("just pushed")
            }
            None => return None,
        };
        if proof.answered() || proof.pending {
            return None;
        }
        proof.pending = true;
        Some((proof.a.clone(), proof.b.clone()))
    }
}
