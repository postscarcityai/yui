// Taps made inside the Mini App (yuigui.com/tg), back to the bot.
//
// Two ways, both carrying the same `[yui] ...` event line:
// 1. WebApp.sendData(line). Telegram only allows it when the Mini App was
//    opened from a reply-keyboard button; the bot gets a message with
//    web_app_data. readWebAppData() takes the line out of it.
// 2. The bridge: when the button link has `bridge=<https url>`, the Mini App
//    POSTs {initData, line} there. That works from inline buttons too. The
//    bot checks initData with its token (verifyInitData) before it trusts
//    who sent the line. Telegram signs initData; the page never sees a secret.

export const LINE = /^\[yui\] [\w~-]+ [a-z]+(?: |$)/;

export type WebAppUser = { id: number; first_name?: string; username?: string; language_code?: string };
export type InitData = { user?: WebAppUser; query_id?: string; auth_date: number; start_param?: string; chat_type?: string };

const enc = new TextEncoder();

async function hmac(key: Uint8Array, data: string) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(data)));
}

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

// Telegram's check (core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app):
// secret = HMAC_SHA256("WebAppData", bot_token); hash = HMAC_SHA256(secret,
// the other fields as sorted key=value lines). Null when it does not match or
// is older than maxAge seconds.
export async function verifyInitData(initData: string, botToken: string, maxAge = 86400, now = Date.now() / 1000): Promise<InitData | null> {
  if (typeof initData !== "string" || !initData || !botToken) return null;
  const q = new URLSearchParams(initData);
  const hash = q.get("hash");
  if (!hash) return null;
  const check = [...q.entries()].filter(([k]) => k !== "hash").map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = await hmac(enc.encode("WebAppData"), botToken);
  if (!timingSafeEqual(hex(await hmac(secret, check)), hash.toLowerCase())) return null;
  const auth = Number(q.get("auth_date"));
  if (!Number.isFinite(auth) || now - auth > maxAge) return null;
  const out: InitData = { auth_date: auth };
  try { if (q.get("user")) out.user = JSON.parse(q.get("user")!); } catch { return null; }
  for (const k of ["query_id", "start_param", "chat_type"] as const) if (q.get(k)) out[k] = q.get(k)!;
  return out;
}

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Signs initData the way Telegram does. For tests and a local bot only: the
// real initData comes from Telegram.
export async function signInitData(fields: Record<string, string>, botToken: string): Promise<string> {
  const check = Object.entries(fields).map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = await hmac(enc.encode("WebAppData"), botToken);
  const q = new URLSearchParams(fields);
  q.set("hash", hex(await hmac(secret, check)));
  return q.toString();
}

// A Telegram message from sendData: the event line, or null.
export function readWebAppData(message: { web_app_data?: { data?: string } } | undefined): string | null {
  const d = message?.web_app_data?.data;
  return typeof d === "string" && d.length <= 4096 && LINE.test(d) ? d : null;
}

// A POST to the bridge: {initData, line}. Returns who sent which line, or why not.
export async function readBridgePost(body: unknown, botToken: string, maxAge?: number): Promise<{ ok: true; user: WebAppUser; line: string } | { ok: false; error: string }> {
  const b = body as { initData?: unknown; line?: unknown } | null;
  if (!b || typeof b.line !== "string" || !LINE.test(b.line) || b.line.length > 4096) return { ok: false, error: "not a Yui event line" };
  const init = await verifyInitData(String(b.initData ?? ""), botToken, maxAge);
  if (!init) return { ok: false, error: "initData did not verify" };
  if (!init.user?.id) return { ok: false, error: "no user in initData" };
  return { ok: true, user: init.user, line: b.line };
}
