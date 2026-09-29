// Makes the connector's vault keypair (YUI-34). The PUBLIC half goes into the
// repo (functions/yui-vault/public_key.txt and connector_key.ts, which the app
// pins); the PRIVATE half is written to the path you give (chmod 600) and is
// then set as the function secret YUI_VAULT_PRIVATE_KEY. It is never committed.
//
//   deno run -A supabase/scripts/vault_keygen.ts <private key file> [key id]
import { b64encode, generateKeyPair, openKey, sealKey } from "../functions/yui-vault/seal.ts";

const [out, keyId = "yvk-1"] = Deno.args;
if (!out) {
  console.error("usage: vault_keygen.ts <private key file> [key id]");
  Deno.exit(2);
}
const here = new URL("../functions/yui-vault/", import.meta.url);
const { publicKey, privateKey } = await generateKeyPair();
// Self-check: seal to the public key, open with the private one.
const back = await openKey(await sealKey("selftest", keyId, publicKey), keyId, privateKey);
if (back !== "selftest") throw new Error("self-check failed");

const pub = b64encode(publicKey);
const rotated = new Date().toISOString().slice(0, 10);
await Deno.writeTextFile(new URL("public_key.txt", here), pub + "\n");
await Deno.writeTextFile(
  new URL("connector_key.ts", here),
  `// The connector's vault PUBLIC key (X25519, base64), pinned by the app and\n` +
    `// published at /.well-known/yui-vault.json. Written by scripts/vault_keygen.ts;\n` +
    `// the private half is the function secret YUI_VAULT_PRIVATE_KEY, never in the repo.\n` +
    `export const KEY_ID = ${JSON.stringify(keyId)};\nexport const PUBLIC_KEY = ${JSON.stringify(pub)};\n` +
    `export const ROTATED_AT = ${JSON.stringify(rotated)};\n`,
);
await Deno.writeTextFile(out, b64encode(privateKey) + "\n", { mode: 0o600 });
await Deno.chmod(out, 0o600);
console.log(`key id ${keyId}\npublic ${pub}\nprivate written to ${out} (mode 600)`);
