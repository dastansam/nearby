//! The NearBy bond contract: layer 3 of the double-spend model.
//!
//! A payer's offline key can sign payments nobody can check against the chain at the time. The
//! payer (or anyone for them) locks NEAR here. Two validly signed vouchers from one key with the
//! same sequence number are a self-contained proof that the key paid twice; whoever holds such a
//! pair submits it, the contract checks both signatures itself, and the key loses its bond and is
//! banned for good. Honest vouchers never come here: they settle on intents.near.
//!
//! The forfeited bond stays in the contract. Paying it to the vouchers' receivers would hand it
//! to whoever the cheat chose to name: they could sign a pair to their own accounts and slash
//! themselves, getting the bond back at once and shutting the real merchants out with a ban.
//! Compensating the merchant who was left unpaid needs settlement evidence this contract does not
//! have, and is roadmap.
use near_sdk::store::LookupMap;
use near_sdk::{env, near, require, AccountId, Gas, NearToken, Promise, PromiseError};
use voucher::{parse_voucher, transfer, Parsed, SignedVoucher, Transfer};

/// How long a withdrawal waits after `unbond`. A payee takes a voucher valid for up to 73 h on
/// an attestation up to 24 h old; the rest is for the voucher to be carried to a relayer.
pub const UNBONDING_NS: u64 = 7 * 24 * 60 * 60 * 1_000_000_000;

/// The least one `bond_for` may attach. Each lock costs the contract storage; a bond of a yocto
/// would let anyone run that up for nothing.
pub const MIN_BOND: NearToken = NearToken::from_near(1);

const ZERO: NearToken = NearToken::from_yoctonear(0);

/// What the contract holds against an account.
#[near(serializers = [borsh])]
pub enum Lock {
    Bonded {
        amount: NearToken,
        /// Whoever paid first. Only they can take the bond out: the offline account it backs has
        /// no NEAR of its own to pay gas with.
        owner: AccountId,
        /// Set by `unbond`: the bond no longer backs new payments and can be withdrawn after the
        /// delay, and is still slashable until then.
        unbonding_since: Option<u64>,
    },
    /// `withdraw`'s transfer is on its way: nothing backs payments or is at stake, and nothing can
    /// be bonded over it. `withdrawn` closes it, or puts the bond back if the transfer failed.
    Withdrawing {
        amount: NearToken,
        owner: AccountId,
        since: u64,
    },
    /// Slashed. For good: the key is a known cheat.
    Banned,
}

#[near(contract_state)]
pub struct Bonds {
    locks: LookupMap<AccountId, Lock>,
}

impl Default for Bonds {
    fn default() -> Self {
        Self {
            locks: LookupMap::new(b"l"),
        }
    }
}

#[near]
impl Bonds {
    /// Lock the attached NEAR as `account`'s bond. Anyone may pay it: the offline account itself
    /// holds only tokens inside intents.near. Whoever paid first owns it, and only they may add to
    /// it: the whole bond leaves with its owner, so anyone else's deposit would be theirs to take.
    /// Adding changes nothing else. Known limit: account ids are public, so a stranger can bond one
    /// first (1 NEAR, locked for 7 days) and keep its wallet from bonding it; binding the owner to
    /// the account's key is roadmap.
    #[payable]
    pub fn bond_for(&mut self, account: AccountId) {
        let deposit = env::attached_deposit();
        require!(deposit >= MIN_BOND, "attach at least 1 NEAR");
        let lock = match self.locks.get(&account) {
            Some(Lock::Banned) => env::panic_str("banned"),
            Some(Lock::Withdrawing { .. }) => env::panic_str("withdrawing"),
            Some(Lock::Bonded {
                amount,
                owner,
                unbonding_since,
            }) => {
                require!(*owner == env::predecessor_account_id(), "not your bond");
                Lock::Bonded {
                    amount: amount.saturating_add(deposit),
                    owner: owner.clone(),
                    unbonding_since: *unbonding_since,
                }
            }
            None => Lock::Bonded {
                amount: deposit,
                owner: env::predecessor_account_id(),
                unbonding_since: None,
            },
        };
        self.locks.insert(account, lock);
    }

    /// Start taking `account`'s bond out, as its owner. It stops backing payments at once, and
    /// stays slashable until withdrawn.
    pub fn unbond(&mut self, account: AccountId) {
        match self.locks.get_mut(&account) {
            Some(Lock::Bonded {
                owner, unbonding_since, ..
            }) if *owner == env::predecessor_account_id() => *unbonding_since = Some(env::block_timestamp()),
            _ => env::panic_str("not your bond"),
        }
    }

    /// Returns `account`'s bond to its owner once the unbonding delay has passed. The lock is
    /// marked first, so the bond cannot be withdrawn twice, and put back if the transfer fails.
    pub fn withdraw(&mut self, account: AccountId) -> Promise {
        let Some(Lock::Bonded {
            amount,
            owner,
            unbonding_since: Some(since),
        }) = self.locks.get(&account)
        else {
            env::panic_str("unbond first")
        };
        require!(*owner == env::predecessor_account_id(), "not your bond");
        require!(
            env::block_timestamp() >= since.saturating_add(UNBONDING_NS),
            "still unbonding"
        );
        let (amount, owner, since) = (*amount, owner.clone(), *since);
        self.locks.insert(
            account.clone(),
            Lock::Withdrawing {
                amount,
                owner: owner.clone(),
                since,
            },
        );
        Promise::new(owner).transfer(amount).then(
            Self::ext(env::current_account_id())
                .with_static_gas(Gas::from_tgas(10))
                .withdrawn(account),
        )
    }

    /// After `withdraw`'s transfer. If it failed (the owner's account is gone, say), the bond is
    /// put back as it was, still unbonding, rather than left here with no record of who it is owed
    /// to; `withdraw` can be called again.
    #[private]
    pub fn withdrawn(&mut self, account: AccountId, #[callback_result] transfer: Result<(), PromiseError>) {
        let Some(Lock::Withdrawing { amount, owner, since }) = self.locks.get(&account) else {
            env::panic_str("not withdrawing")
        };
        let restored = Lock::Bonded {
            amount: *amount,
            owner: owner.clone(),
            unbonding_since: Some(*since),
        };
        match transfer {
            Ok(()) => self.locks.remove(&account),
            Err(_) => self.locks.insert(account, restored),
        };
    }

    /// What backs `account`'s payments right now: nothing while unbonding or once banned.
    pub fn bond_of(&self, account: AccountId) -> NearToken {
        match self.locks.get(&account) {
            Some(Lock::Bonded {
                amount,
                unbonding_since: None,
                ..
            }) => *amount,
            _ => ZERO,
        }
    }

    /// What a proof against `account` would take: the bond, unbonding or not.
    pub fn at_stake(&self, account: AccountId) -> NearToken {
        match self.locks.get(&account) {
            Some(Lock::Bonded { amount, .. }) => *amount,
            _ => ZERO,
        }
    }

    pub fn is_banned(&self, account: AccountId) -> bool {
        matches!(self.locks.get(&account), Some(Lock::Banned))
    }

    /// Two vouchers one key signed with the same sequence number. The key forfeits its bond and is
    /// banned. Returns what it lost.
    ///
    /// A key with nothing at stake is turned away rather than banned: a ban would cost this
    /// contract storage for every pair anyone cares to sign with a throwaway key, and the pair stays
    /// valid, so it can come back the day that key bonds.
    pub fn slash(&mut self, a: SignedVoucher, b: SignedVoucher) -> NearToken {
        let (a, pay_a) = checked(&a);
        let (b, pay_b) = checked(&b);
        require!(a.public_key == b.public_key, "different signers");
        require!(a.hash != b.hash, "the same voucher twice");
        let seq = pay_a.sequence().unwrap_or_else(|| env::panic_str("no sequence number"));
        require!(pay_b.sequence() == Some(seq), "different sequence numbers");

        let account: AccountId = a
            .message
            .signer_id
            .parse()
            .unwrap_or_else(|_| env::panic_str("signer_id"));
        let bond = match self.locks.get(&account) {
            Some(Lock::Bonded { amount, .. }) => *amount,
            Some(Lock::Banned) => env::panic_str("already slashed"),
            // Withdrawing: the NEAR is on its way out, after the 7 days every voucher had to arrive in.
            Some(Lock::Withdrawing { .. }) | None => env::panic_str("nothing at stake"),
        };
        self.locks.insert(account, Lock::Banned);
        env::log_str(&format!(
            "slashed seq {seq}: {} yoctoNEAR forfeited; paid {} and {}",
            bond.as_yoctonear(),
            pay_a.receiver_id,
            pay_b.receiver_id
        ));
        bond
    }
}

/// A voucher the contract believes: well formed, one transfer, and signed by the key it names.
fn checked(v: &SignedVoucher) -> (Parsed, Transfer) {
    let parsed = parse_voucher(v).unwrap_or_else(|why| env::panic_str(why));
    require!(
        env::ed25519_verify(&parsed.signature, parsed.hash, &parsed.public_key),
        "signature"
    );
    let payment = transfer(&parsed.message).unwrap_or_else(|| env::panic_str("intents"));
    (parsed, payment)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use near_sdk::test_utils::VMContextBuilder;
    use near_sdk::testing_env;
    use serde_json::json;
    use voucher::{implicit_account, make_nonce, sign_voucher};

    const NEAR: u128 = 10u128.pow(24);

    fn key() -> SigningKey {
        SigningKey::from_bytes(&rand::random())
    }

    fn account(key: &SigningKey) -> AccountId {
        implicit_account(key.verifying_key().as_bytes()).parse().unwrap()
    }

    /// A payment of 2.5 USDC to `to`, numbered `seq`, with a fresh nonce.
    fn voucher(key: &SigningKey, to: &str, seq: u32) -> SignedVoucher {
        let message = json!({
            "signer_id": account(key),
            "deadline": "2026-11-12T10:00:00.000Z",
            "intents": [{
                "intent": "transfer", "receiver_id": to,
                "tokens": { voucher::USDC_TOKEN: "2500000" }, "memo": format!("req:9f2c seq:{seq} prev:00"),
            }],
        });
        sign_voucher(key, &message, &make_nonce())
    }

    /// Two payments to two merchants with the same sequence number: a double-spend.
    fn pair(key: &SigningKey, seq: u32) -> (SignedVoucher, SignedVoucher) {
        (voucher(key, "cafe.near", seq), voucher(key, "kiosk.near", seq))
    }

    fn call(from: &str, deposit: u128, at_ns: u64) {
        testing_env!(VMContextBuilder::new()
            .predecessor_account_id(from.parse().unwrap())
            .attached_deposit(NearToken::from_yoctonear(deposit))
            .block_timestamp(at_ns)
            .build());
    }

    /// The contract calling itself back after a promise.
    fn callback() {
        testing_env!(VMContextBuilder::new()
            .current_account_id("bond.near".parse().unwrap())
            .predecessor_account_id("bond.near".parse().unwrap())
            .build());
    }

    /// A contract holding `amount` for a fresh key, paid by wallet.near.
    fn bonded(amount: u128) -> (SigningKey, Bonds) {
        let k = key();
        let mut c = Bonds::default();
        call("wallet.near", amount, 0);
        c.bond_for(account(&k));
        (k, c)
    }

    /// A contract holding `amount` for a fresh key, whose owner asked for it back at t = 1000 ns.
    fn unbonding(amount: u128) -> (SigningKey, Bonds) {
        let (k, mut c) = bonded(amount);
        call("wallet.near", 0, 1_000);
        c.unbond(account(&k));
        (k, c)
    }

    #[test]
    fn two_payments_with_one_sequence_number_cost_the_bond_and_the_key() {
        let (k, mut c) = bonded(10 * NEAR);
        let (a, b) = pair(&k, 7);
        assert_eq!(c.slash(a, b).as_yoctonear(), 10 * NEAR);
        assert!(c.bond_of(account(&k)).is_zero());
        assert!(c.at_stake(account(&k)).is_zero());
        assert!(c.is_banned(account(&k)));
    }

    #[test]
    #[should_panic(expected = "banned")]
    fn a_banned_key_cannot_be_bonded_again() {
        let (k, mut c) = bonded(NEAR);
        let (a, b) = pair(&k, 7);
        c.slash(a, b);
        call("wallet.near", NEAR, 0);
        c.bond_for(account(&k));
    }

    // Pairs are free to make with a throwaway key. Storing a ban for each would let anyone run up
    // the contract's storage bill; the pair stays a valid proof if that key ever bonds.
    #[test]
    #[should_panic(expected = "nothing at stake")]
    fn a_pair_from_a_key_that_never_bonded_is_turned_away() {
        let k = key();
        let mut c = Bonds::default();
        let (a, b) = pair(&k, 1);
        c.slash(a, b);
    }

    #[test]
    #[should_panic(expected = "already slashed")]
    fn a_proof_cannot_be_cashed_twice() {
        let (k, mut c) = bonded(NEAR);
        let (a, b) = pair(&k, 7);
        c.slash(a.clone(), b.clone());
        c.slash(a, b);
    }

    // Two copies of one payment are not two payments.
    #[test]
    #[should_panic(expected = "the same voucher twice")]
    fn the_same_voucher_twice_is_not_a_proof() {
        let (k, mut c) = bonded(NEAR);
        let a = voucher(&k, "cafe.near", 7);
        c.slash(a.clone(), a);
    }

    // Parallel payments are the normal case: they carry different sequence numbers.
    #[test]
    #[should_panic(expected = "different sequence numbers")]
    fn two_payments_with_different_sequence_numbers_are_honest() {
        let (k, mut c) = bonded(NEAR);
        c.slash(voucher(&k, "cafe.near", 7), voucher(&k, "kiosk.near", 8));
    }

    #[test]
    #[should_panic(expected = "different signers")]
    fn two_payers_using_the_same_number_prove_nothing() {
        let (k, mut c) = bonded(NEAR);
        c.slash(voucher(&k, "cafe.near", 7), voucher(&key(), "kiosk.near", 7));
    }

    // Anyone can write two messages naming a victim's key; only the key can sign them.
    #[test]
    #[should_panic(expected = "signature")]
    fn a_forged_voucher_cannot_frame_a_payer() {
        let (k, mut c) = bonded(NEAR);
        let mut forged = voucher(&k, "kiosk.near", 7);
        forged.signature = voucher(&key(), "kiosk.near", 7).signature;
        c.slash(voucher(&k, "cafe.near", 7), forged);
    }

    // A payer could otherwise pay offline, pull the bond, and let the vouchers arrive after.
    #[test]
    fn an_unbonding_bond_backs_nothing_but_can_still_be_slashed() {
        let (k, mut c) = unbonding(2 * NEAR);
        let me = account(&k);
        assert!(
            c.bond_of(me.clone()).is_zero(),
            "merchants must stop trusting it at once"
        );
        assert_eq!(c.at_stake(me).as_yoctonear(), 2 * NEAR, "the relayer must still bother");
        call("relayer.near", 0, 1_000 + UNBONDING_NS - 1);
        let (a, b) = pair(&k, 3);
        assert_eq!(c.slash(a, b).as_yoctonear(), 2 * NEAR);
    }

    #[test]
    #[should_panic(expected = "still unbonding")]
    fn withdrawal_waits_out_the_voucher_deadline() {
        let (k, mut c) = unbonding(NEAR);
        call("wallet.near", 0, 1_000 + UNBONDING_NS - 1);
        let _ = c.withdraw(account(&k));
    }

    #[test]
    fn withdrawal_after_the_delay_closes_the_bond() {
        let (k, mut c) = unbonding(NEAR);
        call("wallet.near", 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw(account(&k));
        assert!(c.at_stake(account(&k)).is_zero());
    }

    // The transfer can fail: the owner's account may be gone by then. Without this the NEAR would
    // sit in the contract with no record that anyone is owed it.
    #[test]
    fn a_withdrawal_whose_transfer_failed_is_put_back_to_try_again() {
        let (k, mut c) = unbonding(NEAR);
        let me = account(&k);
        call("wallet.near", 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw(me.clone());
        assert!(
            c.at_stake(me.clone()).is_zero(),
            "nothing to slash or withdraw twice meanwhile"
        );
        callback();
        c.withdrawn(me.clone(), Err(PromiseError::Failed));
        assert_eq!(c.at_stake(me.clone()).as_yoctonear(), NEAR);
        assert!(
            c.bond_of(me.clone()).is_zero(),
            "still unbonding, not backing payments again"
        );
        call("wallet.near", 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw(me.clone());
        callback();
        c.withdrawn(me.clone(), Ok(()));
        assert!(c.at_stake(me).is_zero());
    }

    // While the transfer runs the slot is neither free nor a bond: a stranger bonding it then
    // would be overwritten, or overwrite the bond put back after a failed transfer.
    #[test]
    #[should_panic(expected = "withdrawing")]
    fn a_bond_on_its_way_out_cannot_be_bonded_over() {
        let (k, mut c) = unbonding(NEAR);
        call("wallet.near", 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw(account(&k));
        call("stranger.near", 2 * NEAR, 1_000 + UNBONDING_NS);
        c.bond_for(account(&k));
    }

    #[test]
    #[should_panic(expected = "unbond first")]
    fn a_bond_cannot_be_withdrawn_without_notice() {
        let (k, mut c) = bonded(NEAR);
        call("wallet.near", 0, UNBONDING_NS);
        let _ = c.withdraw(account(&k));
    }

    // The bond is paid by a wallet for an offline key that has no NEAR of its own; the wallet, and
    // nobody else, gets it back.
    #[test]
    #[should_panic(expected = "not your bond")]
    fn only_the_payer_of_a_bond_can_take_it_out() {
        let (k, mut c) = bonded(NEAR);
        call(account(&k).as_str(), 0, 1_000);
        c.unbond(account(&k));
    }

    // Implicit account ids are public (QR codes, attestations). Whoever bonds one first owns the
    // bond and takes all of it out, so a stranger who bonded a payer's account for 1 NEAR would
    // otherwise be handed the 5 NEAR the payer's wallet adds.
    #[test]
    #[should_panic(expected = "not your bond")]
    fn a_stranger_cannot_add_to_a_bond_that_leaves_with_its_owner() {
        let (k, mut c) = bonded(NEAR);
        call("stranger.near", 5 * NEAR, 0);
        c.bond_for(account(&k));
    }

    // Adding must not undo what the owner asked for.
    #[test]
    fn adding_to_an_unbonding_bond_adds_up_and_changes_nothing_else() {
        let (k, mut c) = unbonding(NEAR);
        call("wallet.near", 2 * NEAR, 2_000);
        c.bond_for(account(&k));
        assert!(c.bond_of(account(&k)).is_zero(), "still unbonding");
        assert_eq!(c.at_stake(account(&k)).as_yoctonear(), 3 * NEAR);
        call("wallet.near", 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw(account(&k));
        assert!(c.at_stake(account(&k)).is_zero(), "the owner got it out on time");
    }

    #[test]
    #[should_panic(expected = "attach at least 1 NEAR")]
    fn a_token_bond_is_turned_away() {
        let mut c = Bonds::default();
        call("wallet.near", NEAR - 1, 0);
        c.bond_for(account(&key()));
    }
}
