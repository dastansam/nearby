//! What the relayer must not forget across a restart: the first voucher of every sequence number
//! and the double-spends found. Without it, a restart between a payer's two vouchers lets the
//! cheat go unpunished: the first has settled, so no phone uploads it again. An append-only file of
//! JSON lines, replayed when the relayer starts.
use crate::voucher::SignedVoucher;
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

#[derive(Serialize, Deserialize, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Record {
    /// The first voucher seen with a sequence number, under "signer:seq".
    Seen { slot: String, voucher: SignedVoucher },
    /// A second one: proof that `signer` double-spent.
    Pair {
        signer: String,
        a: SignedVoucher,
        b: SignedVoucher,
    },
    /// What the bond contract made of the pair whose second voucher has signature `b`.
    Answer {
        b: String,
        tx: Option<String>,
        refusal: Option<String>,
    },
}

pub struct Journal(File);

impl Journal {
    /// Opens the journal at `path`, creating it, and returns what it holds. A line that does not
    /// parse (the last one, if a crash cut it short) is skipped and said so.
    pub fn open(path: &Path) -> io::Result<(Self, Vec<Record>)> {
        let mut file = OpenOptions::new().read(true).append(true).create(true).open(path)?;
        let mut text = String::new();
        file.read_to_string(&mut text)?;
        let mut records = Vec::new();
        for (n, line) in text.lines().enumerate().filter(|(_, line)| !line.trim().is_empty()) {
            match serde_json::from_str(line) {
                Ok(record) => records.push(record),
                Err(e) => crate::log(format!("journal line {}: skipped, {e}", n + 1)),
            }
        }
        // A cut-short last line must not swallow the next record appended after it.
        if !text.is_empty() && !text.ends_with('\n') {
            file.write_all(b"\n")?;
        }
        Ok((Self(file), records))
    }

    /// Writes `record` to the file; a pair and the chain's answer about it are forced to disk too.
    /// A first voucher is only written: that survives the relayer being stopped or killed, and
    /// waiting on the disk for every voucher would hold up all the others. A failure is logged, not
    /// fatal: settling goes on, only the memory of this record is at risk.
    pub fn append(&mut self, record: &Record) {
        let mut line = serde_json::to_string(record).expect("a record is JSON");
        line.push('\n');
        let forced = !matches!(record, Record::Seen { .. });
        if let Err(e) = self
            .0
            .write_all(line.as_bytes())
            .and_then(|()| if forced { self.0.sync_data() } else { Ok(()) })
        {
            crate::log(format!("journal: could not write a record: {e}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn voucher(signature: &str) -> SignedVoucher {
        serde_json::from_value(serde_json::json!({
            "standard": "nep413",
            "payload": { "message": "{}", "nonce": "AAAA", "recipient": "intents.near" },
            "public_key": "ed25519:k",
            "signature": signature,
        }))
        .unwrap()
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("nearby-journal-{name}-{:x}", rand::random::<u64>()))
    }

    #[test]
    fn what_was_written_comes_back_in_order() {
        let path = scratch("order");
        let seen = Record::Seen {
            slot: "a:1".into(),
            voucher: voucher("ed25519:one"),
        };
        let answer = Record::Answer {
            b: "ed25519:two".into(),
            tx: Some("tx1".into()),
            refusal: None,
        };
        {
            let (mut journal, empty) = Journal::open(&path).unwrap();
            assert!(empty.is_empty());
            journal.append(&seen);
            journal.append(&answer);
        }
        let (_, back) = Journal::open(&path).unwrap();
        assert_eq!(back, [seen, answer]);
        std::fs::remove_file(path).ok();
    }

    // A crash mid-write leaves half a line. The records before it are still good, and the next
    // record must not be glued to the debris.
    #[test]
    fn a_line_cut_short_by_a_crash_costs_only_itself() {
        let path = scratch("torn");
        let kept = Record::Seen {
            slot: "a:1".into(),
            voucher: voucher("ed25519:one"),
        };
        let line = serde_json::to_string(&kept).unwrap();
        std::fs::write(&path, format!("{line}\n{{\"seen\":{{\"slot\":\"a:2\",\"vou")).unwrap();
        let (mut journal, back) = Journal::open(&path).unwrap();
        assert_eq!(back, std::slice::from_ref(&kept));
        let next = Record::Answer {
            b: "ed25519:x".into(),
            tx: None,
            refusal: Some("nothing at stake".into()),
        };
        journal.append(&next);
        drop(journal);
        let (_, again) = Journal::open(&path).unwrap();
        assert_eq!(again, [kept, next]);
        std::fs::remove_file(path).ok();
    }
}
