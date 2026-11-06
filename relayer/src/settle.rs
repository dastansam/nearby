//! Settling uploaded vouchers, and noticing when a payer has signed two for one sequence number.
use crate::chain::{Chain, ChainError};
use crate::voucher::{verify_voucher, Checked, SignedVoucher, USDC_TOKEN};
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
    /// "signer:seq" -> the first voucher seen with that sequence number.
    by_seq: Remembered<SignedVoucher>,
    equivocations: Vec<(SignedVoucher, SignedVoucher)>,
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
    let [intent] = message.intents.as_slice() else {
        return Err("intents");
    };
    let usdc_only = intent["tokens"]
        .as_object()
        .is_some_and(|tokens| tokens.len() == 1 && tokens.contains_key(USDC_TOKEN));
    if intent["intent"] != "transfer" || !usdc_only {
        return Err("intents");
    }
    // The memo is a space-separated list of entries such as "req:9f2c seq:17 prev:00".
    let memo = intent["memo"].as_str().unwrap_or_default();
    let seq = memo
        .split(' ')
        .find_map(|entry| entry.strip_prefix("seq:"))
        .filter(|seq| !seq.is_empty());
    Ok(Payment {
        seq: seq.map(String::from),
        signer: message.signer_id,
        expired,
        v,
    })
}

pub struct Settler<C> {
    chain: Arc<C>,
    state: Mutex<State>,
}

impl<C: Chain> Settler<C> {
    pub fn new(chain: Arc<C>) -> Self {
        let state = State {
            done: HashMap::new(),
            refused: Remembered::new(),
            by_seq: Remembered::new(),
            equivocations: Vec::new(),
        };
        Self {
            chain,
            state: Mutex::new(state),
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
    pub async fn equivocations(&self) -> Vec<(SignedVoucher, SignedVoucher)> {
        self.state.lock().await.equivocations.clone()
    }

    async fn one(&self, state: &mut State, payment: Payment) -> Outcome {
        let Payment {
            v,
            signer,
            seq,
            expired,
        } = payment;
        if let Some(seq) = seq {
            state.note_sequence(&signer, &seq, &v);
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
        self.chain.simulate(v).await?; // free; execute costs gas even when it fails
        let mut sent = Spent {
            signature: Some(v.signature.clone()),
            tx: Some(self.chain.execute(v).await?),
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
    fn note_sequence(&mut self, signer: &str, seq: &str, v: &SignedVoucher) {
        let slot = format!("{signer}:{seq}");
        match self.by_seq.entries.get(&slot) {
            None => self.by_seq.insert(slot, v.clone()),
            // Compared by signature: two different vouchers may even share a nonce, and only the payer
            // can produce a signature, so nobody else can make a real pair look already recorded.
            Some(first)
                if first.signature != v.signature
                    && !self
                        .equivocations
                        .iter()
                        .any(|(_, second)| second.signature == v.signature) =>
            {
                self.equivocations.push((first.clone(), v.clone()));
            }
            Some(_) => {}
        }
    }
}
