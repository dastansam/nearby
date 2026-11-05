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
  const v = signVoucher(sk, msg, makeNonce("252812b3"));
  assert.equal(verifyVoucher(v).ok, true);
  assert.equal(Buffer.from(v.payload.nonce, "base64").subarray(0, 4).toString("hex"), "252812b3");
});

test("rejects a tampered amount", () => {
  const v = signVoucher(sk, msg, makeNonce("252812b3"));
  v.payload.message = v.payload.message.replace("2500000", "9500000");
  assert.equal(verifyVoucher(v).reason, "signature");
});

test("rejects an expired voucher", () => {
  const v = signVoucher(sk, { ...msg, deadline: "2020-01-01T00:00:00Z" }, makeNonce("252812b3"));
  assert.equal(verifyVoucher(v).reason, "expired");
});

test("parallel vouchers get distinct nonces", () => {
  const a = signVoucher(sk, msg, makeNonce("252812b3"));
  const b = signVoucher(sk, msg, makeNonce("252812b3"));
  assert.notEqual(a.payload.nonce, b.payload.nonce);
});

// The phone signs with app/lib/voucher/nep413.dart, which is pinned to the same vector.
// If this output changes, the two signers have diverged and phone-signed vouchers stop settling.
test("matches the shared cross-language vector", () => {
  const vector = JSON.parse(readFileSync(new URL("../../testdata/voucher-vector.json", import.meta.url), "utf8"));
  const v = signVoucher(Buffer.from(vector.seed_hex, "hex"), vector.message, Buffer.from(vector.nonce_hex, "hex"));
  assert.deepEqual(v, vector.voucher);
});
