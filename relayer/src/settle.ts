// Settling uploaded vouchers, and noticing when a payer has signed two for one sequence number.
import { Refused, type Chain } from "./chain.ts";
import { USDC_TOKEN, verifyVoucher, type IntentMessage, type SignedVoucher } from "./voucher.ts";

export type Result =
  /** On chain. `tx` is missing when someone else settled it or this relayer restarted since. */
  | { status: "settled"; tx?: string }
  /** Not a voucher this relayer settles, or one that can no longer settle. It never will: stop sending it. */
  | { status: "invalid"; reason: string }
  /** The contract refuses it today (say, the payer's balance is short). It may settle later. */
  | { status: "rejected"; reason: string }
  /** The relayer could not reach the chain. Nothing is known about the voucher: send it again. */
  | { status: "error"; reason: string };

const settled = (tx?: string): Result => (tx ? { status: "settled", tx } : { status: "settled" });
const invalid = (reason: string): Result => ({ status: "invalid", reason });

/** How long a refusal is repeated without asking the chain again: every phone carrying the voucher re-uploads it. */
const REFUSAL_TTL_MS = 60_000;

/** Sets `key`, forgetting the oldest entry once the map is full. These maps are fed by anyone who can sign. */
function remember<K, V>(map: Map<K, V>, key: K, value: V, limit = 100_000) {
  if (map.size >= limit) map.delete(map.keys().next().value as K);
  map.set(key, value);
}

export class Settler {
  /** Pairs of vouchers one payer signed with the same sequence number: proof of double-spending. */
  readonly equivocations: [SignedVoucher, SignedVoucher][] = [];

  /**
   * "signer:nonce" -> the voucher that spent that nonce and its tx, when this relayer sent it.
   * An empty entry means the chain says the nonce is spent and we do not know by which voucher.
   */
  private readonly done = new Map<string, { signature?: string; tx?: string }>();
  private readonly refused = new Map<string, { reason: string; until: number }>(); // by signature
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
    let v: SignedVoucher, msg: IntentMessage, expired: boolean;
    try {
      // Only the fields the contract hashes go on: an extra one would change what it verifies.
      const { standard, payload: { message, nonce, recipient }, public_key, signature } = input as SignedVoucher;
      v = { standard, payload: { message, nonce, recipient }, public_key, signature };
      const check = verifyVoucher(v);
      // "expired" is the last check, so an expired voucher is still validly signed. It is handled
      // below: it may have settled in time through another gateway, and it still proves a double-spend.
      expired = check.reason === "expired";
      if (!check.ok && !expired) return invalid(check.reason!);
      msg = check.message ?? (JSON.parse(v.payload.message) as IntentMessage);
      // The relayer pays gas for NearBy payments (one USDC transfer), not for whatever else someone signs.
      const [intent, ...rest] = msg.intents;
      if (rest.length > 0 || intent?.intent !== "transfer" || Object.keys(intent.tokens).join() !== USDC_TOKEN) {
        return invalid("intents");
      }
      this.noteSequence(msg, v);
    } catch {
      return invalid("malformed");
    }

    const signer = msg.signer_id, slot = `${signer}:${v.payload.nonce}`;
    try {
      // A nonce settles one voucher. Another voucher on the same nonce did not get paid by that
      // transaction, so it must not be told "settled".
      const spent = this.done.get(slot);
      if (spent) return spent.signature === undefined || spent.signature === v.signature ? settled(spent.tx) : invalid("nonce spent by another voucher");
      const refusal = this.refused.get(v.signature);
      if (refusal && refusal.until > Date.now()) return { status: "rejected", reason: refusal.reason };
      if (await this.chain.isNonceUsed(signer, v.payload.nonce)) {
        this.done.set(slot, {});
        return settled();
      }
      if (expired) return invalid("expired");
      await this.chain.simulate(v); // free; execute costs gas even when it fails
      const tx = await this.chain.execute(v);
      this.done.set(slot, { signature: v.signature, tx });
      return settled(tx);
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      if (!(e instanceof Refused)) return { status: "error", reason };
      remember(this.refused, v.signature, { reason, until: Date.now() + REFUSAL_TTL_MS });
      return { status: "rejected", reason };
    }
  }

  /** Both vouchers of a pair still go to the chain, which settles whichever the balance allows. */
  private noteSequence(msg: IntentMessage, v: SignedVoucher) {
    // The memo is a space-separated list of entries such as "req:9f2c seq:17 prev:00".
    const seq = /(?:^| )seq:(\S+)/.exec(msg.intents[0].memo ?? "")?.[1];
    if (seq === undefined) return;
    const slot = `${msg.signer_id}:${seq}`, first = this.bySeq.get(slot);
    // Compared by signature: two different vouchers may even share a nonce, and only the payer
    // can produce a signature, so nobody else can make a real pair look already recorded.
    if (first === undefined) remember(this.bySeq, slot, v);
    else if (first.signature !== v.signature && !this.equivocations.some(([, b]) => b.signature === v.signature)) {
      this.equivocations.push([first, v]);
    }
  }
}
