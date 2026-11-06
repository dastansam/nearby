// Settling uploaded vouchers, and noticing when a payer has signed two for one sequence number.
import { Refused, type Chain } from "./chain.ts";
import { verifyVoucher, type IntentMessage, type SignedVoucher } from "./voucher.ts";

export type Result =
  /** On chain. `tx` is missing when someone else settled it or this relayer restarted since. */
  | { status: "settled"; tx?: string }
  /** Not a voucher this relayer settles. It never will be. */
  | { status: "invalid"; reason: string }
  /** The contract refuses it today (say, the payer's balance is short). It may settle later. */
  | { status: "rejected"; reason: string }
  /** The relayer could not reach the chain. Nothing is known about the voucher: send it again. */
  | { status: "error"; reason: string };

const settled = (tx?: string): Result => (tx ? { status: "settled", tx } : { status: "settled" });

export class Settler {
  /** Pairs of vouchers one payer signed with the same sequence number: proof of double-spending. */
  readonly equivocations: [SignedVoucher, SignedVoucher][] = [];

  private readonly done = new Map<string, string | undefined>(); // "signer:nonce" -> tx hash, when this relayer sent it
  private readonly bySeq = new Map<string, SignedVoucher>(); // "signer:seq" -> first voucher seen
  private queue: Promise<unknown> = Promise.resolve();

  constructor(private readonly chain: Chain) {}

  /**
   * One result per input, in order. Across all uploads, vouchers are handled one at a time: two
   * gateways often carry the same voucher, and the relayer's access key signs one transaction at
   * a time. Uploads take turns voucher by voucher, so a long one does not hold up a short one.
   */
  async settle(vouchers: unknown[]): Promise<Result[]> {
    const results: Result[] = [];
    for (const v of vouchers) {
      const result = this.queue.then(() => this.one(v));
      this.queue = result.catch(() => {});
      results.push(await result);
    }
    return results;
  }

  private async one(input: unknown): Promise<Result> {
    let v: SignedVoucher, signer: string;
    try {
      // Only the fields the contract hashes go on: an extra one would change what it verifies.
      const { standard, payload: { message, nonce, recipient }, public_key, signature } = input as SignedVoucher;
      v = { standard, payload: { message, nonce, recipient }, public_key, signature };
      const check = verifyVoucher(v);
      // An expired voucher is still validly signed, and proof of double-spending does not expire with it.
      if (check.ok || check.reason === "expired") this.noteSequence(v);
      if (!check.ok) return { status: "invalid", reason: check.reason! };
      // The relayer pays gas for NearBy payments, not for whatever else someone signs.
      const intents = check.message!.intents;
      if (intents.length !== 1 || intents[0].intent !== "transfer") return { status: "invalid", reason: "intents" };
      signer = check.message!.signer_id;
    } catch {
      return { status: "invalid", reason: "malformed" };
    }

    const key = `${signer}:${v.payload.nonce}`;
    try {
      if (this.done.has(key)) return settled(this.done.get(key));
      if (!(await this.chain.isNonceUsed(signer, v.payload.nonce))) {
        await this.chain.simulate(v); // free; execute costs gas even when it fails
        this.done.set(key, await this.chain.execute(v));
      } else {
        this.done.set(key, undefined);
      }
      return settled(this.done.get(key));
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      return { status: e instanceof Refused ? "rejected" : "error", reason };
    }
  }

  /** Both vouchers of a pair still go to the chain, which settles whichever the balance allows. */
  private noteSequence(v: SignedVoucher) {
    const msg = JSON.parse(v.payload.message) as IntentMessage;
    // The memo is a space-separated list of entries such as "req:9f2c seq:17 prev:00".
    const seq = /(?:^| )seq:(\S+)/.exec(msg.intents?.[0]?.memo ?? "")?.[1];
    if (seq === undefined) return;
    const slot = `${msg.signer_id}:${seq}`, first = this.bySeq.get(slot);
    if (first === undefined) this.bySeq.set(slot, v);
    else if (first.payload.nonce !== v.payload.nonce && !this.equivocations.some(([, b]) => b.payload.nonce === v.payload.nonce)) {
      this.equivocations.push([first, v]);
    }
  }
}
