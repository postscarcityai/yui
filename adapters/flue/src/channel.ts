// The Yui channel's Web-only half (INT-13): the turn shape, the channel guide,
// and verified HTTP ingress for pushed turns. Fetch and Web Crypto only, no
// node: imports, so it runs on Flue's Cloudflare target as well as on Node
// (import it as `yui-flue/channel` there). The dial-out connector is in yui.ts.
// -- the turn --------------------------------------------------------------------------

export interface YuiGuide { version: string; body: string }

/** A tap on a screen, as the phone sent it (spec/RELAY.md "Events"). */
export interface YuiEvent { id: string; preset: string; value?: Record<string, unknown>; echo?: string; [k: string]: unknown }

export interface YuiTurn {
  /** The Yui agent this turn is for. `ref` is its remote_ref, to route between Flue agents. */
  agent: { id: string; name: string; handle?: string; ref: string };
  /** The person's rows this turn answers, oldest first. */
  turn: string[];
  /** Stable for these rows, across restarts: use it as the dispatch idempotencyKey. */
  key: string;
  /** The person's words, one row per line. A tap is its `[yui] <id> <preset> key=value` line. */
  text: string;
  messages: { id: string; kind: string; body: string; event: YuiEvent | null; created_at: string }[];
  guide: YuiGuide;
}

/** The project's side: send the turn to a Flue agent and return its reply (null or "" for none).
 * Throw to try the same turn again later (same key). */
export type Answer = (turn: YuiTurn) => Promise<string | null | undefined>;

let currentGuide: YuiGuide = { version: "", body: "" };

/** The newest channel guide this process has seen (from a Yui session or a pushed turn). */
export function yuiGuide(): YuiGuide {
  return currentGuide;
}

/** The agent's own instructions plus the Yui channel guide. */
export function withYuiGuide(instructions: string): string {
  const g = currentGuide.body.trim();
  return g ? `${instructions.trim()}\n\n${g}` : instructions;
}

/** Keeps the guide a pushed turn or a Yui session brought. */
export function setYuiGuide(g: YuiGuide): void {
  if (g?.body) currentGuide = { version: String(g.version ?? ""), body: String(g.body) };
}

/** The webhook bridge's x-yui-turn for these rows: sha256 of the ids joined by commas, 32 hex. */
export async function turnKeyOf(turn: string[]): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(turn.join(",")));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

// -- push in: the channel (verified HTTP ingress) ------------------------------------------------

/** The parts of a Hono context the route uses, so this module needs no hono import. */
interface Ctx {
  req: { text(): Promise<string>; header(name: string): string | undefined };
  json(body: unknown, status?: number): Response;
  body(data: null, status?: number): Response;
}

export interface ChannelOptions {
  /** The shared secret the sender signs with (the webhook bridge's --secret). Required. */
  secret: string;
  answer: Answer;
  /** Seconds a signed timestamp stays good (default 300). */
  tolerance?: number;
  maxBytes?: number;
}

const enc = new TextEncoder();

async function hmacOk(secret: string, ts: string, raw: string, header: string): Promise<boolean> {
  const hex = header.startsWith("sha256=") ? header.slice(7) : "";
  if (!/^[0-9a-f]{64}$/.test(hex)) return false;
  const sig = new Uint8Array(hex.match(/../g)!.map((b) => parseInt(b, 16)));
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("HMAC", key, sig, enc.encode(`${ts}.${raw}`)); // constant time
}

export function createYuiChannel(opts: ChannelOptions) {
  if (!opts.secret) throw new Error("createYuiChannel needs a secret: an unsigned route would let anyone talk as the person");
  const tolerance = opts.tolerance ?? 300;
  const maxBytes = opts.maxBytes ?? 1_000_000;

  // Path: /channels/yui/webhook
  const webhook = async (c: Ctx): Promise<Response> => {
    if (!(c.req.header("content-type") ?? "").includes("application/json")) return c.json({ error: "json only" }, 415);
    const raw = await c.req.text();
    if (enc.encode(raw).length > maxBytes) return c.json({ error: "too large" }, 413);
    const ts = c.req.header("x-yui-timestamp") ?? "";
    if (!/^\d{1,12}$/.test(ts) || Math.abs(Date.now() / 1000 - Number(ts)) > tolerance) return c.json({ error: "stale or missing timestamp" }, 401);
    if (!await hmacOk(opts.secret, ts, raw, c.req.header("x-yui-signature") ?? "")) return c.json({ error: "bad signature" }, 401);
    let p: any;
    try {
      p = JSON.parse(raw);
    } catch {
      return c.json({ error: "bad json" }, 400);
    }
    if (!p?.agent?.id || !Array.isArray(p.turn) || !p.turn.length || typeof p.text !== "string") {
      return c.json({ error: "not a Yui turn" }, 400);
    }
    setYuiGuide(p.guide);
    const turn: YuiTurn = {
      agent: { id: String(p.agent.id), name: String(p.agent.name ?? ""), handle: p.agent.handle, ref: String(p.agent.ref ?? "") },
      turn: p.turn.map(String),
      key: c.req.header("x-yui-turn") || await turnKeyOf(p.turn.map(String)),
      text: p.text,
      messages: Array.isArray(p.messages) ? p.messages : [],
      guide: currentGuide,
    };
    const text = ((await opts.answer(turn)) ?? "").trim();
    return text ? c.json({ reply: text }) : c.body(null, 204);
  };

  return { routes: [{ method: "POST" as const, path: "/webhook", handler: webhook }] };
}
