// A Yui Lines document packed into a URL-safe string: base64url of raw
// deflate, the same format as yuigui's share links (site/lib/share-code.mjs),
// so yuigui.com/tg and /playground read it. CompressionStream is in Node 18+,
// Deno, Workers and browsers.
async function pipe(bytes: Uint8Array, stream: CompressionStream | DecompressionStream) {
  const out = new Response(new Blob([bytes]).stream().pipeThrough(stream));
  return new Uint8Array(await out.arrayBuffer());
}

const b64url = (bytes: Uint8Array) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

export async function encodeYL(text: string): Promise<string> {
  return b64url(await pipe(new TextEncoder().encode(text), new CompressionStream("deflate-raw")));
}

export async function decodeYL(code: string): Promise<string | null> {
  if (!/^[A-Za-z0-9_-]+$/.test(code)) return null;
  try {
    const bin = atob(code.replace(/-/g, "+").replace(/_/g, "/"));
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(await pipe(bytes, new DecompressionStream("deflate-raw")));
  } catch {
    return null;
  }
}
