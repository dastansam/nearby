// Gate 1: does a voucher signed with today's salt still settle later?
//   npm run salt-test -- sign   -> fetches current_salt, writes voucher.json (signed by an offline key)
//   npm run salt-test -- submit -> (hours later) prints current salt and submits voucher.json via simulate/execute
// Needs: OFFLINE_SK (hex ed25519 seed, its implicit account funded in intents.near),
//        RELAYER_ACCOUNT + RELAYER_KEY (ed25519:... key for a funded mainnet account), RECEIVER, TOKEN, AMOUNT.
import { readFileSync, writeFileSync } from "node:fs";
import { ed25519 } from "@noble/curves/ed25519";
import { implicitAccount, makeNonce, signVoucher, type SignedVoucher } from "../src/voucher.ts";

const RPC = process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org";

async function view(method: string, args: object = {}) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "query",
      params: { request_type: "call_function", finality: "final", account_id: "intents.near", method_name: method,
        args_base64: Buffer.from(JSON.stringify(args)).toString("base64") },
    }),
  });
  const j = await res.json();
  if (j.error || j.result?.error) throw new Error(JSON.stringify(j.error ?? j.result.error));
  return JSON.parse(Buffer.from(j.result.result).toString());
}

const mode = process.argv[2];
if (mode === "sign") {
  const sk = Buffer.from(process.env.OFFLINE_SK!, "hex");
  const salt = await view("current_salt");
  const signer = implicitAccount(ed25519.getPublicKey(sk));
  const v = signVoucher(sk, {
    signer_id: signer,
    deadline: new Date(Date.now() + 72 * 3600e3).toISOString(),
    intents: [{ intent: "transfer", receiver_id: process.env.RECEIVER!, tokens: { [process.env.TOKEN!]: process.env.AMOUNT! } }],
  }, makeNonce(salt));
  writeFileSync("voucher.json", JSON.stringify({ signedAt: new Date().toISOString(), salt, v }, null, 2));
  console.log("signed with salt", salt, "signer", signer);
} else if (mode === "submit") {
  const { signedAt, salt, v } = JSON.parse(readFileSync("voucher.json", "utf8")) as { signedAt: string; salt: string; v: SignedVoucher };
  console.log("signed at", signedAt, "with salt", salt, "| current salt", await view("current_salt"));
  // simulate_intents is a view; it reports invalid salt/nonce/deadline before we spend gas.
  // TODO(day 1): confirm the exact arg shape against the verifier Rust docs ({ signed: [...] } is the expected form).
  console.log(JSON.stringify(await view("simulate_intents", { signed: [v] }), null, 2));
  // TODO: execute_intents via near-api-js with RELAYER_ACCOUNT once simulate passes.
} else {
  console.log("usage: salt-test sign|submit");
}
