// What the relayer needs from NEAR. An interface so the settlement rules can be tested without a network.
import { connect, KeyPair, keyStores } from "near-api-js";
import { VERIFYING_CONTRACT, type SignedVoucher } from "./voucher.ts";

export interface Chain {
  /** Base units of `token` the account holds inside intents.near, and the block height that was read at. */
  balanceOf(account: string, token: string): Promise<{ balance: string; block: number }>;
  /**
   * Whether a voucher with this signer and nonce has settled (or the nonce was otherwise spent),
   * as of `block`. The contract spends the nonce and moves the tokens in one step, so a balance
   * read at that height or later already includes the payment, and one read earlier does not.
   */
  isNonceUsed(account: string, nonceBase64: string): Promise<{ used: boolean; block: number }>;
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
  /** A view call together with the height it ran at, which near-api-js's viewFunction drops. */
  const viewAt = async (method_name: string, args: object) => {
    const r = await account.connection.provider.query<{ result: number[]; block_height: number; block_hash: string }>({
      request_type: "call_function",
      account_id: VERIFYING_CONTRACT,
      method_name,
      args_base64: Buffer.from(JSON.stringify(args)).toString("base64"),
      finality: "optimistic",
    });
    return { value: JSON.parse(Buffer.from(r.result).toString()), block: r.block_height };
  };
  return {
    balanceOf: async (account_id, token_id) => {
      const { value, block } = await viewAt("mt_balance_of", { account_id, token_id });
      return { balance: value as string, block };
    },
    isNonceUsed: async (account_id, nonce) => {
      const { value, block } = await viewAt("is_nonce_used", { account_id, nonce });
      return { used: value as boolean, block };
    },
    simulate: async (v) => void (await view("simulate_intents", { signed: [v] }).catch(refusal)),
    execute: async (v) =>
      (await account
        .functionCall({ contractId: VERIFYING_CONTRACT, methodName: "execute_intents", args: { signed: [v] }, gas: 300_000_000_000_000n })
        .catch(refusal)).transaction.hash,
  };
}
