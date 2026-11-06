// Runs the relayer. Needs:
//   RELAYER_ACCOUNT, RELAYER_KEY  a mainnet account with NEAR for gas and its ed25519:... key. It only
//                                 pays gas: a voucher's own signature is what moves tokens.
//   ATTESTATION_SK                hex ed25519 seed that signs balance attestations. GET / prints the
//                                 public key to pin in the app. Keep it separate from RELAYER_KEY.
// Optional: NEAR_RPC, PORT (default 8787).
import { nearChain } from "./chain.ts";
import { buildServer } from "./server.ts";

const { RELAYER_ACCOUNT, RELAYER_KEY, ATTESTATION_SK } = process.env;
if (!RELAYER_ACCOUNT || !RELAYER_KEY || !/^[0-9a-f]{64}$/.test(ATTESTATION_SK ?? "")) {
  throw new Error("set RELAYER_ACCOUNT, RELAYER_KEY and ATTESTATION_SK (64 hex characters)");
}
const chain = await nearChain({ accountId: RELAYER_ACCOUNT, key: RELAYER_KEY, rpc: process.env.NEAR_RPC });
const app = buildServer({ chain, attestationKey: Buffer.from(ATTESTATION_SK!, "hex") });
// All interfaces: the phones reach the relayer over the network, not from this machine.
console.log("relayer listening on", await app.listen({ port: Number(process.env.PORT ?? 8787), host: "0.0.0.0" }));
