// NEP-413 signed transfer intents ("vouchers") for intents.near.
// Reference implementation; app/lib/voucher/nep413.dart must produce identical bytes.
import { ed25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { randomBytes } from "@noble/hashes/utils";
import bs58 from "bs58";

export const VERIFYING_CONTRACT = "intents.near";
const NEP413_TAG = 2 ** 31 + 413;

export interface TransferIntent {
  intent: "transfer";
  receiver_id: string;
  tokens: Record<string, string>; // e.g. { "nep141:usdc.near": "2500000" }
  memo?: string;
}

export interface IntentMessage {
  signer_id: string;
  deadline: string; // ISO 8601
  intents: TransferIntent[];
}

export interface SignedVoucher {
  standard: "nep413";
  payload: { message: string; nonce: string; recipient: string };
  public_key: string; // ed25519:<base58>
  signature: string; // ed25519:<base58>
}

/** 32-byte nonce = 4-byte contract salt (hex from `current_salt`) + 28 random bytes. */
export function makeNonce(saltHex: string): Uint8Array {
  const salt = Buffer.from(saltHex, "hex");
  if (salt.length !== 4) throw new Error("salt must be 4 bytes");
  const n = new Uint8Array(32);
  n.set(salt, 0);
  n.set(randomBytes(28), 4);
  return n;
}

function borshU32(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n, true);
  return b;
}
function borshString(s: string): Uint8Array {
  const bytes = new TextEncoder().encode(s);
  return concat(borshU32(bytes.length), bytes);
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/** sha256(borsh(tag) || borsh({message, nonce[32], recipient, callback_url: None})) */
export function nep413Hash(message: string, nonce: Uint8Array, recipient: string): Uint8Array {
  if (nonce.length !== 32) throw new Error("nonce must be 32 bytes");
  return sha256(concat(borshU32(NEP413_TAG), borshString(message), nonce, borshString(recipient), new Uint8Array([0])));
}

/** Implicit account id = hex of the ed25519 public key. */
export const implicitAccount = (pub: Uint8Array) => Buffer.from(pub).toString("hex");

export function signVoucher(secretKey: Uint8Array, msg: IntentMessage, nonce: Uint8Array): SignedVoucher {
  const pub = ed25519.getPublicKey(secretKey);
  const message = JSON.stringify(msg);
  const sig = ed25519.sign(nep413Hash(message, nonce, VERIFYING_CONTRACT), secretKey);
  return {
    standard: "nep413",
    payload: { message, nonce: Buffer.from(nonce).toString("base64"), recipient: VERIFYING_CONTRACT },
    public_key: "ed25519:" + bs58.encode(pub),
    signature: "ed25519:" + bs58.encode(sig),
  };
}

export interface VerifyResult { ok: boolean; reason?: string; message?: IntentMessage }

/** Offline checks a merchant runs. Balance/attestation checks live in the app. */
export function verifyVoucher(v: SignedVoucher, now = new Date()): VerifyResult {
  if (v.standard !== "nep413") return { ok: false, reason: "standard" };
  if (v.payload.recipient !== VERIFYING_CONTRACT) return { ok: false, reason: "recipient" };
  const pub = bs58.decode(v.public_key.replace(/^ed25519:/, ""));
  const sig = bs58.decode(v.signature.replace(/^ed25519:/, ""));
  const nonce = Buffer.from(v.payload.nonce, "base64");
  const hash = nep413Hash(v.payload.message, nonce, v.payload.recipient);
  if (!ed25519.verify(sig, hash, pub)) return { ok: false, reason: "signature" };
  const msg = JSON.parse(v.payload.message) as IntentMessage;
  if (msg.signer_id !== implicitAccount(pub)) return { ok: false, reason: "signer_id" };
  if (new Date(msg.deadline) <= now) return { ok: false, reason: "expired" };
  return { ok: true, message: msg };
}

/** Stable id used for dedup across the mesh. */
export const voucherId = (v: SignedVoucher) => Buffer.from(sha256(new TextEncoder().encode(v.signature))).toString("hex");
