// What the relayer needs from NEAR. An interface so the settlement rules can be tested without a network.
import { connect, KeyPair, keyStores } from "near-api-js";
import { VERIFYING_CONTRACT, type SignedVoucher } from "./voucher.ts";

export interface Chain {
  /** Base units of `token` the account holds inside intents.near. */
  balanceOf(account: string, token: string): Promise<string>;
  /** True once a voucher with this signer and nonce has settled (or the nonce was otherwise spent). */
  isNonceUsed(account: string, nonceBase64: string): Promise<boolean>;
  /** A free dry run. Throws [Refused] if the voucher would not settle right now. */
  simulate(v: SignedVoucher): Promise<void>;
  /** Settles the voucher, paying gas. Returns the transaction hash. Throws [Refused] if the contract turns it down. */
  execute(v: SignedVoucher): Promise<string>;
}

/**
 * The contract itself refused the voucher; the message is its reason ("insufficient balance or
 * overflow", "deadline has expired"). Any other error from a Chain means it could not be reached
 * and says nothing about the voucher: a refusal is an answer, an outage means try again.
 */
export class Refused extends Error {}

/** Rethrows a near-api-js error, as [Refused] when it is the contract panicking. */
function refusal(e: unknown): never {
  const text = e instanceof Error ? e.message : String(e);
  const reason = /panic_msg: "((?:[^"\\]|\\.)*)"/.exec(text)?.[1] ?? /Smart contract panicked: (.*)/.exec(text)?.[1];
  throw reason === undefined ? e : new Refused(reason);
}

export async function nearChain(opts: { accountId: string; key: string; rpc?: string }): Promise<Chain> {
  const keyStore = new keyStores.InMemoryKeyStore();
  await keyStore.setKey("mainnet", opts.accountId, KeyPair.fromString(opts.key as Parameters<typeof KeyPair.fromString>[0]));
  const nodeUrl = opts.rpc ?? "https://rpc.mainnet.near.org";
  const account = await (await connect({ networkId: "mainnet", nodeUrl, keyStore })).account(opts.accountId);
  const view = (methodName: string, args: object) => account.viewFunction({ contractId: VERIFYING_CONTRACT, methodName, args });
  return {
    balanceOf: (account_id, token_id) => view("mt_balance_of", { account_id, token_id }),
    isNonceUsed: (account_id, nonce) => view("is_nonce_used", { account_id, nonce }),
    simulate: async (v) => void (await view("simulate_intents", { signed: [v] }).catch(refusal)),
    execute: async (v) =>
      (await account
        .functionCall({ contractId: VERIFYING_CONTRACT, methodName: "execute_intents", args: { signed: [v] }, gas: 300_000_000_000_000n })
        .catch(refusal)).transaction.hash,
  };
}
