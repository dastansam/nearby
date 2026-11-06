import { test } from "node:test";
import assert from "node:assert/strict";
import { ed25519 } from "@noble/curves/ed25519";
import bs58 from "bs58";
import { ATTESTATION_DOMAIN } from "./attestation.ts";
import { Refused, type Chain } from "./chain.ts";
import { buildServer } from "./server.ts";
import { Settler } from "./settle.ts";
import { implicitAccount, makeNonce, signVoucher, USDC_TOKEN, type SignedVoucher } from "./voucher.ts";

/** A stand-in for intents.near that records what the relayer asked of it. */
class FakeChain implements Chain {
  used = new Set<string>(); // "account:nonce" already settled on chain
  refuse = new Map<string, string>(); // nonce -> the contract's panic message
  down = false;
  lookups = 0; // view calls made
  executed: SignedVoucher[] = [];
  balance = "25000000";

  private reach() {
    if (this.down) throw new Error("fetch failed");
    this.lookups++;
  }
  async balanceOf() {
    this.reach();
    return this.balance;
  }
  async isNonceUsed(account: string, nonce: string) {
    this.reach();
    return this.used.has(`${account}:${nonce}`);
  }
  async simulate(v: SignedVoucher) {
    this.reach();
    const why = this.refuse.get(v.payload.nonce);
    if (why) throw new Refused(why);
  }
  async execute(v: SignedVoucher) {
    this.reach();
    this.executed.push(v);
    return `tx${this.executed.length}`;
  }
}

const sk = ed25519.utils.randomPrivateKey();
const signer = implicitAccount(ed25519.getPublicKey(sk));
const pay = (o: { to?: string; memo?: string; intents?: object[]; key?: Uint8Array; validForHours?: number; nonce?: Uint8Array } = {}) => {
  const key = o.key ?? sk;
  return signVoucher(key, {
    signer_id: implicitAccount(ed25519.getPublicKey(key)),
    deadline: new Date(Date.now() + (o.validForHours ?? 72) * 3600e3).toISOString(),
    intents: (o.intents ?? [{
      intent: "transfer", receiver_id: o.to ?? "merchant.near", tokens: { [USDC_TOKEN]: "2500000" },
      ...(o.memo ? { memo: o.memo } : {}),
    }]) as never,
  }, o.nonce ?? makeNonce());
};

test("settles an uploaded voucher and says where", async () => {
  const chain = new FakeChain(), v = pay();
  // The gateway shows the tx to the user and stops carrying the voucher.
  assert.deepEqual(await new Settler(chain).settle([v]), [{ status: "settled", tx: "tx1" }]);
  assert.deepEqual(chain.executed, [v]);
});

// Every phone that carried a voucher uploads it. Executing it again would burn gas on a
// transaction the chain must refuse, once per extra gateway.
test("a voucher uploaded by several gateways is executed once", async () => {
  const chain = new FakeChain(), settler = new Settler(chain), v = pay();
  const [a, b] = await Promise.all([settler.settle([v]), settler.settle([v])]);
  assert.deepEqual([a, b], [[{ status: "settled", tx: "tx1" }], [{ status: "settled", tx: "tx1" }]]);
  assert.equal(chain.executed.length, 1);
});

test("a voucher already on chain is reported settled without paying gas again", async () => {
  // After a relayer restart, or when another relayer or the payee settled it themselves.
  const chain = new FakeChain(), v = pay();
  chain.used.add(`${signer}:${v.payload.nonce}`);
  assert.deepEqual(await new Settler(chain).settle([v]), [{ status: "settled" }]);
  assert.equal(chain.executed.length, 0);
});

// The chain settles one voucher per signer and nonce. A payer who signs two on one nonce pays
// only one merchant; telling the other "settled", with the first one's transaction, would hide the theft.
test("a second voucher on a spent nonce is not reported as settled", async () => {
  const chain = new FakeChain(), settler = new Settler(chain), nonce = makeNonce();
  const paid = pay({ to: "merchant.near", nonce }), cheated = pay({ to: "other.near", nonce });
  assert.deepEqual(await settler.settle([paid, cheated, paid]), [
    { status: "settled", tx: "tx1" },
    { status: "invalid", reason: "nonce spent by another voucher" },
    { status: "settled", tx: "tx1" },
  ]);
  assert.deepEqual(chain.executed, [paid]);
});

test("a voucher that settled before it expired is still reported settled afterwards", async () => {
  // A payee whose phone comes back online days later must learn it was paid, not see "expired".
  const chain = new FakeChain(), v = pay({ validForHours: -1 });
  chain.used.add(`${signer}:${v.payload.nonce}`);
  assert.deepEqual(await new Settler(chain).settle([v]), [{ status: "settled" }]);
  assert.equal(chain.executed.length, 0);
});

test("a refused voucher uploaded again straight away is answered without asking the chain", async () => {
  // Every phone that carries it re-uploads it every half minute; the answer will not have changed.
  const chain = new FakeChain(), settler = new Settler(chain), broke = pay();
  chain.refuse.set(broke.payload.nonce, "insufficient balance or overflow");
  const first = await settler.settle([broke]), asked = chain.lookups;
  assert.deepEqual(await settler.settle([broke]), first);
  assert.equal(chain.lookups, asked);
});

test("a voucher the contract would refuse costs no gas, and does not hold up the others", async () => {
  const chain = new FakeChain(), broke = pay(), fine = pay();
  chain.refuse.set(broke.payload.nonce, "insufficient balance or overflow");
  assert.deepEqual(await new Settler(chain).settle([broke, fine]), [
    // "rejected", not "invalid": the payer may top up, so the phone keeps carrying it.
    { status: "rejected", reason: "insufficient balance or overflow" },
    { status: "settled", tx: "tx1" },
  ]);
  assert.deepEqual(chain.executed, [fine]);
});

test("when the chain is unreachable the phone is told to try again, not that the voucher is bad", async () => {
  const chain = new FakeChain();
  chain.down = true;
  const [result] = await new Settler(chain).settle([pay()]);
  assert.equal(result.status, "error");
});

test("what is not a NearBy payment never reaches the chain", async () => {
  // The relayer pays the gas, so it settles single transfers only and nothing unverified.
  const chain = new FakeChain();
  const tampered = pay();
  tampered.payload.message = tampered.payload.message.replace("merchant.near", "thief.near");
  const transfer = { intent: "transfer", receiver_id: "a.near", tokens: { [USDC_TOKEN]: "1" } };
  const results = await new Settler(chain).settle([
    tampered,
    pay({ intents: [transfer, transfer] }),
    pay({ intents: [{ intent: "ft_withdraw", token: "usdc.near", receiver_id: "a.near", amount: "1" }] }),
    pay({ intents: [{ intent: "transfer", receiver_id: "a.near", tokens: { "nep141:wrap.near": "1" } }] }),
    { hello: "world" },
    null,
  ]);
  assert.deepEqual(results.map((r) => r.status === "invalid" && r.reason),
    ["signature", "intents", "intents", "intents", "malformed", "malformed"]);
  assert.equal(chain.executed.length, 0);
});

test("a field the contract would hash is not passed on", async () => {
  // intents.near hashes payload.callback_url if present; the signature was made without it.
  const chain = new FakeChain(), v = pay();
  await new Settler(chain).settle([{ ...v, payload: { ...v.payload, callback_url: "x" }, extra: 1 }]);
  assert.deepEqual(chain.executed, [v]);
});

// Layer 2 of the double-spend model: two vouchers with one sequence number are a self-contained
// proof that the payer cheated, and the relayer is where both halves finally meet.
test("two vouchers with the same sequence number are kept as proof, and both still go to the chain", async () => {
  const chain = new FakeChain(), settler = new Settler(chain);
  const first = pay({ to: "merchant.near", memo: "req:aa seq:4 prev:00" });
  const second = pay({ to: "other.near", memo: "seq:4 prev:00" });
  await settler.settle([first, pay({ memo: "seq:5 prev:00" })]);
  await settler.settle([second, second, first]);
  assert.deepEqual(settler.equivocations, [[first, second]]);
  assert.equal(chain.executed.length, 3, "the chain decides which of the pair the balance covers");
});

test("an expired voucher is not settled but still counts as half of a proof", async () => {
  // The cheated merchant's voucher often reaches the relayer late. The payer's two signatures
  // prove the double-spend whether or not the voucher could still settle.
  const chain = new FakeChain(), settler = new Settler(chain);
  const first = pay({ memo: "seq:4 prev:00" }), late = pay({ to: "other.near", memo: "seq:4 prev:00", validForHours: -1 });
  assert.deepEqual((await settler.settle([first, late]))[1], { status: "invalid", reason: "expired" });
  assert.deepEqual(settler.equivocations, [[first, late]]);
  assert.deepEqual(chain.executed, [first]);
});

test("a long upload does not make a short one wait for all of it", async () => {
  // One phone carrying a festival's worth of vouchers must not delay everyone else's payments.
  const chain = new FakeChain(), settler = new Settler(chain);
  const long = [pay(), pay(), pay(), pay()], short = pay();
  await Promise.all([settler.settle(long), settler.settle([short])]);
  assert.ok(chain.executed.indexOf(short) < 3, `the short upload was served at position ${chain.executed.indexOf(short)}`);
});

test("a pair that reuses the nonce as well as the sequence number is still proof", async () => {
  const settler = new Settler(new FakeChain()), nonce = makeNonce();
  const first = pay({ memo: "seq:4 prev:00", nonce }), second = pay({ to: "other.near", memo: "seq:4 prev:00", nonce });
  await settler.settle([first, second]);
  assert.deepEqual(settler.equivocations, [[first, second]]);
});

test("someone else's pair cannot make a real proof look already recorded", async () => {
  // Nonces are public once a voucher is gossiped; a cheat could plant a pair that reuses theirs.
  const settler = new Settler(new FakeChain()), nonce = makeNonce(), throwaway = ed25519.utils.randomPrivateKey();
  await settler.settle([pay({ memo: "seq:1 prev:00", key: throwaway }), pay({ memo: "seq:1 prev:00", key: throwaway, nonce })]);
  const first = pay({ memo: "seq:4 prev:00" }), second = pay({ to: "other.near", memo: "seq:4 prev:00", nonce });
  await settler.settle([first, second]);
  assert.deepEqual(settler.equivocations[1], [first, second]);
});

test("the same sequence number from two different payers is not a double-spend", async () => {
  const settler = new Settler(new FakeChain());
  await settler.settle([pay({ memo: "seq:1 prev:00" }), pay({ memo: "seq:1 prev:00", key: ed25519.utils.randomPrivateKey() })]);
  assert.deepEqual(settler.equivocations, []);
});

const attestationKey = ed25519.utils.randomPrivateKey();
const server = (chain: Chain, now = new Date("2026-11-10T09:00:00.000Z")) =>
  buildServer({ chain, attestationKey, now: () => now });

test("a gateway uploads its outbox over HTTP and gets one result per voucher", async () => {
  const chain = new FakeChain(), v = pay();
  const res = await server(chain).inject({ method: "POST", url: "/vouchers", payload: { vouchers: [v, {}] } });
  assert.deepEqual(res.json(), { results: [{ status: "settled", tx: "tx1" }, { status: "invalid", reason: "malformed" }] });
  assert.equal((await server(chain).inject({ method: "POST", url: "/vouchers", payload: { nope: 1 } })).statusCode, 400);
});

// A payee with no network hands over goods on the strength of this statement, so it must be
// the chain's number, signed by the key the app pins, and bound to the account and time.
test("an attestation is the chain balance signed by the relayer's published key", async () => {
  const chain = new FakeChain(), app = server(chain);
  const signed = (await app.inject({ url: `/attestation/${signer}` })).json();
  assert.deepEqual(JSON.parse(signed.payload), {
    account: signer, token: USDC_TOKEN, balance: "25000000", bond: "0", as_of: "2026-11-10T09:00:00.000Z",
  });
  const published = (await app.inject({ url: "/" })).json().attestation_key as string;
  const verify = (payload: string) => ed25519.verify(
    bs58.decode(signed.signature.replace("ed25519:", "")),
    new TextEncoder().encode(ATTESTATION_DOMAIN + payload),
    bs58.decode(published.replace("ed25519:", "")));
  assert.equal(verify(signed.payload), true);
  assert.equal(verify(signed.payload.replace("25000000", "95000000")), false);
});

test("no attestation for something that is not an offline account, or when the balance is unknown", async () => {
  const chain = new FakeChain();
  assert.equal((await server(chain).inject({ url: "/attestation/merchant.near" })).statusCode, 400);
  chain.down = true;
  assert.equal((await server(chain).inject({ url: `/attestation/${signer}` })).statusCode, 500);
});
