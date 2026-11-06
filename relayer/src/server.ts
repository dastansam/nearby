// HTTP face of the relayer. Nothing here needs authentication: vouchers authorize themselves by
// signature, balances are public, and an attestation is only as good as the relayer's signature on it.
import { ed25519 } from "@noble/curves/ed25519";
import bs58 from "bs58";
import Fastify from "fastify";
import { signAttestation } from "./attestation.ts";
import type { Chain } from "./chain.ts";
import { Settler } from "./settle.ts";
import { USDC_TOKEN } from "./voucher.ts";

/** A phone's whole outbox fits well under this; more is not a phone. */
const MAX_VOUCHERS = 500;

export function buildServer(opts: { chain: Chain; attestationKey: Uint8Array; now?: () => Date }) {
  const now = opts.now ?? (() => new Date());
  const settler = new Settler(opts.chain);
  const app = Fastify();

  /** The key the app must pin to trust this relayer's attestations. */
  app.get("/", () => ({
    name: "nearby-relayer",
    attestation_key: "ed25519:" + bs58.encode(ed25519.getPublicKey(opts.attestationKey)),
  }));

  /** A gateway phone uploads what it carries. One result per voucher, in order. */
  app.post("/vouchers", async (req, reply) => {
    const vouchers = (req.body as { vouchers?: unknown } | null)?.vouchers;
    if (!Array.isArray(vouchers) || vouchers.length > MAX_VOUCHERS) {
      return reply.code(400).send({ error: `send { "vouchers": [...] } with at most ${MAX_VOUCHERS}` });
    }
    return { results: await settler.settle(vouchers) };
  });

  /** What an offline account holds right now, signed, for the app to show payees while offline. */
  app.get("/attestation/:account", async (req, reply) => {
    const { account } = req.params as { account: string };
    // Offline accounts are implicit ones: the hex of the key that signs their vouchers.
    if (!/^[0-9a-f]{64}$/.test(account)) return reply.code(400).send({ error: "not an implicit account" });
    const { balance, block } = await opts.chain.balanceOf(account, USDC_TOKEN);
    return signAttestation(opts.attestationKey, { account, token: USDC_TOKEN, balance, bond: "0" /* no bond contract yet */, as_of: now().toISOString(), block });
  });

  /** Proofs of double-spending seen so far, for whoever submits them to the bond contract. */
  app.get("/equivocations", () => settler.equivocations);

  return app;
}
