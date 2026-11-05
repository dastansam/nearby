// Gate 1: does a voucher signed now still settle later?
//   npm run settle-test -- sign   -> writes voucher.json, signed by an offline key; needs no network
//   npm run settle-test -- submit -> (hours later) simulates voucher.json, then settles it with execute_intents
// sign needs:   OFFLINE_SK (hex ed25519 seed, its implicit account funded in intents.near), RECEIVER, TOKEN, AMOUNT.
// submit needs: RELAYER_ACCOUNT + RELAYER_KEY (ed25519:... full-access or function-call key of a mainnet
//               account with NEAR for gas). It pays gas only; the voucher's signature moves the tokens.
import { readFileSync, writeFileSync } from "node:fs";
import { ed25519 } from "@noble/curves/ed25519";
import { connect, KeyPair, keyStores } from "near-api-js";
import { implicitAccount, makeNonce, signVoucher, VERIFYING_CONTRACT, type SignedVoucher } from "../src/voucher.ts";

const RPC = process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org";

const mode = process.argv[2];
if (mode === "sign") {
  const sk = Buffer.from(process.env.OFFLINE_SK!, "hex");
  const signer = implicitAccount(ed25519.getPublicKey(sk));
  const v = signVoucher(sk, {
    signer_id: signer,
    deadline: new Date(Date.now() + 72 * 3600e3).toISOString(),
    intents: [{ intent: "transfer", receiver_id: process.env.RECEIVER!, tokens: { [process.env.TOKEN!]: process.env.AMOUNT! } }],
  }, makeNonce());
  writeFileSync("voucher.json", JSON.stringify({ signedAt: new Date().toISOString(), v }, null, 2));
  console.log("signed by", signer);
} else if (mode === "submit") {
  const { signedAt, v } = JSON.parse(readFileSync("voucher.json", "utf8")) as { signedAt: string; v: SignedVoucher };
  console.log("signed at", signedAt);
  const accountId = process.env.RELAYER_ACCOUNT, key = process.env.RELAYER_KEY;
  if (!accountId || !key) throw new Error("set RELAYER_ACCOUNT and RELAYER_KEY");
  const keyStore = new keyStores.InMemoryKeyStore();
  await keyStore.setKey("mainnet", accountId, KeyPair.fromString(key as Parameters<typeof KeyPair.fromString>[0]));
  const account = await (await connect({ networkId: "mainnet", nodeUrl: RPC, keyStore })).account(accountId);
  const call = { contractId: VERIFYING_CONTRACT, args: { signed: [v] } };
  // simulate_intents is a view: it throws on a bad signature, nonce, deadline or balance before we spend gas.
  console.log("simulated:", JSON.stringify(await account.viewFunction({ ...call, methodName: "simulate_intents" })));
  const outcome = await account.functionCall({ ...call, methodName: "execute_intents", gas: 300_000_000_000_000n });
  console.log("settled: https://nearblocks.io/txns/" + outcome.transaction.hash);
} else {
  console.log("usage: settle-test sign|submit");
}
