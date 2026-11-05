import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ed25519 } from "@noble/curves/ed25519";
import { implicitAccount, makeNonce, signVoucher, verifyVoucher } from "./voucher.ts";

const sk = ed25519.utils.randomPrivateKey();
const signer = implicitAccount(ed25519.getPublicKey(sk));
const msg = {
  signer_id: signer,
  deadline: new Date(Date.now() + 72 * 3600e3).toISOString(),
  intents: [{ intent: "transfer" as const, receiver_id: "merchant.near", tokens: { "nep141:usdc.near": "2500000" } }],
};

test("signs and verifies a voucher", () => {
  const v = signVoucher(sk, msg, makeNonce());
  assert.equal(verifyVoucher(v).ok, true);
  assert.equal(Buffer.from(v.payload.nonce, "base64").length, 32);
});

test("rejects a tampered amount", () => {
  const v = signVoucher(sk, msg, makeNonce());
  v.payload.message = v.payload.message.replace("2500000", "9500000");
  assert.equal(verifyVoucher(v).reason, "signature");
});

test("rejects an expired voucher", () => {
  const v = signVoucher(sk, { ...msg, deadline: "2020-01-01T00:00:00.000Z" }, makeNonce());
  assert.equal(verifyVoucher(v).reason, "expired");
});

// The contract rejects these at settlement, after the relayer has paid gas. "garbage" used to
// pass outright, because an invalid date is never "<= now".
test("rejects a deadline that is not the UTC form we sign", () => {
  for (const deadline of ["garbage", "2099-01-01T00:00:00", "20990101T000000Z"]) {
    assert.equal(verifyVoucher(signVoucher(sk, { ...msg, deadline }, makeNonce())).reason, "deadline", deadline);
  }
});

// Mainnet rejects "5628f6c6 + version + salt + deadline" nonces with "invalid salt" or "deadline is
// greater than nonce". A payer could craft one that verifies offline and never settles.
test("rejects a versioned nonce, whose salt and expiry cannot be checked offline", () => {
  const crafted = new Uint8Array(32).fill(7);
  crafted.set([0x56, 0x28, 0xf6, 0xc6, 0]);
  assert.equal(verifyVoucher(signVoucher(sk, msg, crafted)).reason, "nonce");
});

test("parallel vouchers get distinct nonces", () => {
  const a = signVoucher(sk, msg, makeNonce());
  const b = signVoucher(sk, msg, makeNonce());
  assert.notEqual(a.payload.nonce, b.payload.nonce);
});

// The phone signs with app/lib/voucher/nep413.dart, which is pinned to the same vector.
// If this output changes, the two signers have diverged and phone-signed vouchers stop settling.
test("matches the shared cross-language vector", () => {
  const vector = JSON.parse(readFileSync(new URL("../../testdata/voucher-vector.json", import.meta.url), "utf8"));
  const v = signVoucher(Buffer.from(vector.seed_hex, "hex"), vector.message, Buffer.from(vector.nonce_hex, "hex"));
  assert.deepEqual(v, vector.voucher);
});
