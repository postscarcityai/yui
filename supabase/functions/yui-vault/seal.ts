// Opening a sealed key (VAULT.md section 4, CONTRACT 5): HPKE base mode,
// DHKEM(X25519, HKDF-SHA256) + HKDF-SHA256 + ChaCha20-Poly1305, which is
// CryptoKit's HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly.
//   info   = utf8("yui-vault-v1|" + key_id)   key_id: the connector key's id
//   sealed = enc (32 bytes) || ciphertext || tag
//   plaintext = utf8 key
import { CipherSuite, HkdfSha256 } from "npm:@hpke/core@1";
import { DhkemX25519HkdfSha256 } from "npm:@hpke/dhkem-x25519@1";
import { Chacha20Poly1305 } from "npm:@hpke/chacha20poly1305@1";

const suite = () => new CipherSuite({ kem: new DhkemX25519HkdfSha256(), kdf: new HkdfSha256(), aead: new Chacha20Poly1305() });
const te = new TextEncoder();

export const infoFor = (keyId: string) => te.encode("yui-vault-v1|" + keyId);

export function b64decode(s: string): Uint8Array {
  const t = s.trim().replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(t + "=".repeat((4 - (t.length % 4)) % 4)), (c) => c.charCodeAt(0));
}
export const b64encode = (b: Uint8Array) => btoa(String.fromCharCode(...b));
export const hexToBytes = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (x) => parseInt(x, 16));

// Opens one blob with a raw 32-byte X25519 private key. Throws on anything wrong.
export async function openKey(sealed: Uint8Array, keyId: string, privateKey: Uint8Array): Promise<string> {
  if (sealed.length < 49) throw new Error("sealed too short");
  const s = suite();
  const recipientKey = await s.kem.deserializePrivateKey(privateKey);
  const ctx = await s.createRecipientContext({ recipientKey, enc: sealed.slice(0, 32), info: infoFor(keyId) });
  return new TextDecoder().decode(await ctx.open(sealed.slice(32)));
}

// The app's side, for tests and the keygen self-check.
export async function sealKey(plaintext: string, keyId: string, publicKey: Uint8Array): Promise<Uint8Array> {
  const s = suite();
  const recipientPublicKey = await s.kem.deserializePublicKey(publicKey);
  const ctx = await s.createSenderContext({ recipientPublicKey, info: infoFor(keyId) });
  const ct = new Uint8Array(await ctx.seal(te.encode(plaintext)));
  const out = new Uint8Array(32 + ct.length);
  out.set(new Uint8Array(ctx.enc), 0);
  out.set(ct, 32);
  return out;
}

export async function generateKeyPair(): Promise<{ publicKey: Uint8Array; privateKey: Uint8Array }> {
  const s = suite();
  const kp = await s.kem.generateKeyPair();
  return {
    publicKey: new Uint8Array(await s.kem.serializePublicKey(kp.publicKey)),
    privateKey: new Uint8Array(await s.kem.serializePrivateKey(kp.privateKey)),
  };
}
