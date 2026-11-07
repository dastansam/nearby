//! The NearBy bond contract: layer 3 of the double-spend model.
//!
//! A payer's offline key can sign payments nobody can check against the chain at the time. The
//! payer (or anyone for them) locks NEAR here. Two validly signed vouchers from one key with the
//! same sequence number are a self-contained proof that the key paid twice; whoever holds such a
//! pair submits it, the contract checks both signatures itself, pays the bond to the two vouchers'
//! receivers and bans the key for good. Honest vouchers never come here: they settle on intents.near.
use near_sdk::store::LookupMap;
use near_sdk::{env, near, require, AccountId, NearToken, Promise};
use voucher::{parse_voucher, transfer, Parsed, SignedVoucher, Transfer};

/// How long a withdrawal waits after `unbond`. Vouchers carry a 72 h deadline, and one relayed
/// late must still find a bond to slash.
pub const UNBONDING_NS: u64 = 4 * 24 * 60 * 60 * 1_000_000_000;

const ZERO: NearToken = NearToken::from_yoctonear(0);

/// What the contract holds against an account.
#[near(serializers = [borsh])]
pub enum Lock {
    /// `unbonding_since` is set by `unbond`: the bond no longer backs new payments and can be
    /// withdrawn after the delay, and is still slashable until then.
    Bonded {
        amount: NearToken,
        unbonding_since: Option<u64>,
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
    /// holds only tokens inside intents.near. Bonding again cancels an unbonding in progress.
    #[payable]
    pub fn bond_for(&mut self, account: AccountId) {
        let deposit = env::attached_deposit();
        require!(!deposit.is_zero(), "attach the bond");
        let amount = match self.locks.get(&account) {
            Some(Lock::Banned) => env::panic_str("banned"),
            Some(Lock::Bonded { amount, .. }) => amount.saturating_add(deposit),
            None => deposit,
        };
        self.locks.insert(
            account,
            Lock::Bonded {
                amount,
                unbonding_since: None,
            },
        );
    }

    /// Start taking the caller's bond out. It stops backing payments at once, and stays slashable
    /// until withdrawn.
    pub fn unbond(&mut self) {
        match self.locks.get_mut(&env::predecessor_account_id()) {
            Some(Lock::Bonded { unbonding_since, .. }) => *unbonding_since = Some(env::block_timestamp()),
            _ => env::panic_str("no bond"),
        }
    }

    pub fn withdraw(&mut self) -> Promise {
        let account = env::predecessor_account_id();
        let Some(Lock::Bonded {
            amount,
            unbonding_since: Some(since),
        }) = self.locks.get(&account)
        else {
            env::panic_str("unbond first")
        };
        require!(
            env::block_timestamp() >= since.saturating_add(UNBONDING_NS),
            "still unbonding"
        );
        let amount = *amount;
        self.locks.remove(&account);
        Promise::new(account).transfer(amount)
    }

    /// What backs `account`'s payments right now: nothing while unbonding or once banned.
    pub fn bond_of(&self, account: AccountId) -> NearToken {
        match self.locks.get(&account) {
            Some(Lock::Bonded {
                amount,
                unbonding_since: None,
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

    /// Two vouchers one key signed with the same sequence number. Pays the key's bond to the two
    /// receivers, half each, and bans the key. Returns what was paid out.
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
            None => env::panic_str("nothing at stake"),
        };
        self.locks.insert(account, Lock::Banned);
        env::log_str(&format!(
            "slashed seq {seq}: {} yoctoNEAR to {} and {}",
            bond.as_yoctonear(),
            pay_a.receiver_id,
            pay_b.receiver_id
        ));
        let half = NearToken::from_yoctonear(bond.as_yoctonear() / 2);
        pay(&pay_a.receiver_id, half);
        pay(&pay_b.receiver_id, bond.saturating_sub(half));
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

/// A transfer scheduled alongside the call's own result (a dropped Promise still runs).
fn pay(to: &str, amount: NearToken) {
    let to: AccountId = to.parse().unwrap_or_else(|_| env::panic_str("receiver_id"));
    let _ = Promise::new(to).transfer(amount);
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

    /// A contract holding `amount` for a fresh key.
    fn bonded(amount: u128) -> (SigningKey, Bonds) {
        let k = key();
        let mut c = Bonds::default();
        call("wallet.near", amount, 0);
        c.bond_for(account(&k));
        (k, c)
    }

    /// A contract holding `amount` for a fresh key that asked for it back at t = 1000 ns.
    fn unbonding(amount: u128) -> (SigningKey, Bonds) {
        let (k, mut c) = bonded(amount);
        call(account(&k).as_str(), 0, 1_000);
        c.unbond();
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
        call(account(&k).as_str(), 0, 1_000 + UNBONDING_NS - 1);
        let _ = c.withdraw();
    }

    #[test]
    fn withdrawal_after_the_delay_closes_the_bond() {
        let (k, mut c) = unbonding(NEAR);
        call(account(&k).as_str(), 0, 1_000 + UNBONDING_NS);
        let _ = c.withdraw();
        assert!(c.at_stake(account(&k)).is_zero());
    }

    #[test]
    #[should_panic(expected = "unbond first")]
    fn a_bond_cannot_be_withdrawn_without_notice() {
        let (k, mut c) = bonded(NEAR);
        call(account(&k).as_str(), 0, UNBONDING_NS);
        let _ = c.withdraw();
    }

    #[test]
    fn bonding_again_cancels_unbonding_and_adds_up() {
        let (k, mut c) = unbonding(NEAR);
        call("wallet.near", 2 * NEAR, 2_000);
        c.bond_for(account(&k));
        assert_eq!(c.bond_of(account(&k)).as_yoctonear(), 3 * NEAR);
    }
}
