// Balance attestations: the relayer's signed statement of what an offline account held at a
// point in time. A payee with no network accepts a voucher only up to this amount, so the
// relayer key that signs these is pinned in the app.
import { ed25519 } from "@noble/curves/ed25519";
import bs58 from "bs58";

export interface Attestation {
  account: string;
  token: string;
  balance: string; // token base units inside intents.near
  bond: string;
  as_of: string; // ISO 8601; the app treats it as valid for 24 h
  /**
   * Height of the block the balance was read at. A payment settled by this height is already in
   * the balance; a later one is not. Heights, not clocks: the reading and the settlement can
   * come from RPC nodes that are a block apart.
   */
  block: number;
}

export interface SignedAttestation {
  payload: string; // the Attestation as JSON, signed as these exact bytes
  signature: string; // ed25519:<base58>
}

/** Prefixed to the payload before signing, so this key's signatures cannot be passed off as anything else. */
export const ATTESTATION_DOMAIN = "NearBy balance attestation v1\n";

export function signAttestation(secretKey: Uint8Array, a: Attestation): SignedAttestation {
  const { account, token, balance, bond, as_of, block } = a;
  const payload = JSON.stringify({ account, token, balance, bond, as_of, block });
  const sig = ed25519.sign(new TextEncoder().encode(ATTESTATION_DOMAIN + payload), secretKey);
  return { payload, signature: "ed25519:" + bs58.encode(sig) };
}
