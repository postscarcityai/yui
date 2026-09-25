// The Yui side of a TypeScript connector (INT-18 step 1, shared with INT-13 Flue).
//
// Same relay rules as the webhook bridge (adapters/webhook, INT-2) and the
// Hermes plugin: rows in yui_messages are the contract (yuigui/spec/RELAY.md),
// every person's row is marked delivered when a turn starts and handled once
// its answer is written, replies name their rows in meta.turn, and anything
// that must survive a crash is on disk before it happens.
//
// This module knows nothing about the agent on the other side. The A2A bridge
// (bridge.ts) and the Flue channel (adapters/flue) each extend YuiRelay with
// their own turn: how a turn reaches the agent and how its answer comes back.
//
// Node only (files, crypto). The hosted step moves this into a Durable Object.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { dirname } from "node:path";

export const SUPABASE_URL = process.env.YUI_SUPABASE_URL ?? "https://ewzzaoperdpxqxkshynx.supabase.co";
const CONNECT = `${SUPABASE_URL}/functions/v1/yui-connect`;
const PUSH = `${SUPABASE_URL}/functions/v1/yui-push`;
const REST = `${SUPABASE_URL}/rest/v1`;
// Public client key (anon role only; it cannot read any yui_ table).
const PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS";
const HEARTBEAT_SECONDS = 45;
const REFRESH_MARGIN_SECONDS = 600;
export const BACKOFF_MAX = 60;
export const MAX_BODY = 32000;

export const nowIso = () => new Date().toISOString();
export const sleep = (s: number) => new Promise((r) => setTimeout(r, s * 1000));
export const logger = (name: string) => (msg: string) => console.error(`${new Date().toTimeString().slice(0, 8)} ${name}: ${msg}`);

/** Yui said no for good (bad token, removed host): stop, don't retry. */
export class Refused extends Error {}
/** Network or server trouble on Yui's side: try again later. */
export class Retry extends Error {}

// -- state ------------------------------------------------------------------------------

/** The turn in flight for one Yui agent. On disk before the message goes out.
 * Each connector adds its own handle on the agent's side (A2A: taskId). */
export interface Inflight {
  turn: string[]; // the person's rows this turn answers
  messageId: string;
  started: number;
  [k: string]: unknown;
}

export interface StateData {
  token?: string;
  connector?: { id: string; name: string; kind?: string };
  floors: Record<string, string>;
  outbox: { row: any; ack: string[]; queued_at: number }[];
  acks: string[];
  inflight: Record<string, Inflight>; // Yui agent id -> turn in flight
  [k: string]: any; // the connector's own keys (A2A: remotes, open)
}

export class State<D extends StateData = StateData> {
  path: string;
  data: D;
  constructor(path: string, defaults: Partial<Record<keyof D, unknown>> = {}) {
    this.path = path;
    let d: any = {};
    try {
      d = JSON.parse(readFileSync(path, "utf8"));
    } catch {}
    for (const [k, v] of Object.entries({ floors: {}, outbox: [], acks: [], inflight: {}, ...defaults })) {
      d[k] ??= structuredClone(v);
    }
    this.data = d;
  }
  save(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = this.path.replace(/\.json$/, "") + ".tmp";
    writeFileSync(tmp, JSON.stringify(this.data, null, 1), { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}

// -- HTTP to Yui ----------------------------------------------------------------------------

export async function http(method: string, url: string, body?: unknown, headers: Record<string, string> = {},
                           timeout = 20, ua = "yui-connector/1"): Promise<[number, any]> {
  let r: Response;
  try {
    r = await fetch(url, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "content-type": "application/json", apikey: PUBLISHABLE, "user-agent": ua, ...headers },
      signal: AbortSignal.timeout(timeout * 1000),
    });
  } catch (e: any) {
    throw new Retry(String(e?.cause?.code ?? e?.message ?? e));
  }
  const text = await r.text();
  let data: any = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return [r.status, data];
}

export async function connectCall(body: Record<string, unknown>, token?: string, ua?: string): Promise<any> {
  const [s, r] = await http("POST", CONNECT, body, token ? { authorization: `Bearer ${token}` } : {}, 20, ua);
  if (s === 401 || s === 403) throw new Refused(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  if (s >= 300) throw new Retry(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  return r ?? {};
}

/** A remote_ref from a name: "Currency Agent" -> "currency-agent". */
export function refFromName(name: string, fallback = "agent"): string {
  const s = name.toLowerCase().replace(/[^a-z0-9_.-]+/g, "-").replace(/^[^a-z0-9]+|-+$/g, "").slice(0, 64);
  return s || fallback;
}

/** Claims the app's 6-digit code for remote_ref `ref`. A new connector resets the state's relay keys. */
export async function pairConnector(state: State, code: string, ref: string, opts: { hostName?: string; kind?: string;
                                    reset?: Record<string, unknown>; ua?: string } = {}): Promise<any> {
  const auth: Record<string, string> = state.data.token ? { authorization: `Bearer ${state.data.token}` } : {};
  const [s, r] = await http("POST", CONNECT, {
    action: "pair", code, remote_ref: ref, host_name: opts.hostName ?? (hostname().split(".")[0] || "My computer"),
    kind: opts.kind ?? "http",
  }, auth, 20, opts.ua);
  if (s !== 200) throw new Refused(`pair failed: ${r?.error ?? s}`);
  if (r.connector_token) { // a new connector (first pairing, or another Yui account)
    Object.assign(state.data, { token: r.connector_token, connector: r.connector, floors: {}, outbox: [], acks: [],
                                inflight: {}, ...structuredClone(opts.reset ?? {}) });
  }
  // Messages sent from the moment of pairing reach the agent, even before `run`.
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

/** Another agent on an already paired machine: a new Yui agent, no code. */
export async function addAgent(state: State, ref: string, name?: string, ua?: string): Promise<any> {
  if (!state.data.token) throw new Refused("not paired yet: run `pair <code>` first");
  const r = await connectCall({ action: "add", remote_ref: ref, ...(name ? { name } : {}) }, state.data.token, ua);
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

// -- the relay -------------------------------------------------------------------------------------

export interface YuiAgent { id: string; name: string; handle?: string; remote_ref: string }
export interface Row { id: string; agent_id: string; body: string; kind: string; meta: any; created_at: string; delivered_at: string | null }

export class YuiRelay<D extends StateData = StateData> {
  state: State<D>;
  ua: string;
  log: (msg: string) => void;
  token: string | null = null;
  userId: string | null = null;
  tokenExp = 0;
  agents = new Map<string, YuiAgent>();
  guide = { version: "", body: "" };
  running = true;
  private beat?: ReturnType<typeof setInterval>;
  private beating?: Promise<unknown>;
  private flushing: Promise<void> = Promise.resolve();

  constructor(state: State<D>, opts: { ua?: string; log?: (msg: string) => void } = {}) {
    this.state = state;
    this.ua = opts.ua ?? "yui-connector/1";
    this.log = opts.log ?? logger("yui");
  }

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code>`");
    return this.state.data.token;
  }

  connect(body: Record<string, unknown>): Promise<any> {
    return connectCall(body, this.ct, this.ua);
  }

  /** Called once per agent the first time a session lists it. */
  protected onAgent(_a: YuiAgent): void {}

  async session(): Promise<void> {
    const r = await this.connect({ action: "session" });
    this.token = r.access_token;
    this.userId = r.user_id;
    this.tokenExp = Date.parse(r.expires_at) / 1000;
    this.guide = r.guide ?? this.guide;
    const agents = new Map<string, YuiAgent>((r.agents ?? []).map((a: YuiAgent) => [a.id, a]));
    for (const [id, a] of agents) {
      if (this.agents.has(id)) continue;
      if (!this.state.data.floors[id]) { // an agent added later starts from now
        this.state.data.floors[id] = nowIso();
        this.state.save();
      }
      this.onAgent(a);
    }
    this.agents = agents;
  }

  async ensureSession(): Promise<void> {
    if (!this.token || this.tokenExp - Date.now() / 1000 < REFRESH_MARGIN_SECONDS) await this.session();
  }

  async rest(method: string, path: string, body?: unknown, prefer?: string): Promise<[number, any]> {
    const headers = (): Record<string, string> => ({ authorization: `Bearer ${this.token}`, ...(prefer ? { prefer } : {}) });
    let [s, r] = await http(method, `${REST}/${path}`, body, headers(), 20, this.ua);
    if (s === 401) {
      await this.session();
      [s, r] = await http(method, `${REST}/${path}`, body, headers(), 20, this.ua);
    }
    return [s, r];
  }

  // -- acks (RELAY.md, Delivery) --

  async mark(ids: string[], column: "delivered_at" | "handled_at"): Promise<boolean> {
    let q = `yui_messages?id=in.(${ids.join(",")})`;
    if (column === "delivered_at") q += "&delivered_at=is.null"; // keep the first pickup time
    try {
      const [s] = await this.rest("PATCH", q, { [column]: nowIso() }, "return=minimal");
      return s < 300;
    } catch (e) {
      if (e instanceof Retry) return false;
      throw e;
    }
  }

  async flushAcks(): Promise<void> {
    const ids = [...this.state.data.acks];
    if (ids.length && await this.mark(ids, "handled_at")) {
      this.state.data.acks = this.state.data.acks.filter((i) => !ids.includes(i));
      this.state.save();
    }
  }

  /** An earlier run already answered this row: a reply names it in meta.turn. */
  async answered(row: Row): Promise<boolean> {
    if (this.state.data.outbox.some((i) => (i.row.meta?.turn ?? []).includes(row.id))) return true;
    const [s, r] = await this.rest("GET", `yui_messages?select=id&agent_id=eq.${row.agent_id}&sender=eq.agent`
      + `&meta->turn=cs.${encodeURIComponent(JSON.stringify([row.id]))}&limit=1`);
    return s === 200 && r.length > 0;
  }

  // -- agent to phone --

  /** Puts the reply in the outbox and ends the turn in one save, so a crash can't split them. */
  queueReply(agentId: string, text: string, turn: string[]): void {
    const row = { id: randomUUID(), user_id: this.userId, agent_id: agentId, sender: "agent", kind: "text",
                  body: text.trim().slice(0, MAX_BODY), meta: { turn } };
    this.state.data.outbox.push({ row, ack: turn, queued_at: Date.now() / 1000 });
    delete this.state.data.inflight[agentId];
    this.state.save();
  }

  /** A turn with nothing to say: done, no reply. */
  endTurn(agentId: string, turn: string[]): void {
    delete this.state.data.inflight[agentId];
    this.state.data.acks.push(...turn);
    this.state.save();
  }

  /** Oldest first; a reply that can't go yet holds the ones behind it. Serialized across agents. */
  flushOutbox(): Promise<void> {
    const run = this.flushing.catch(() => {}).then(() => this.flushNow());
    this.flushing = run;
    return run;
  }

  private async flushNow(): Promise<void> {
    while (this.state.data.outbox.length) {
      const item = this.state.data.outbox[0];
      const [s, r] = await this.rest("POST", "yui_messages", item.row, "return=minimal");
      if (s >= 300 && s !== 409) { // 409: an earlier try got through
        if ([408, 425, 429].includes(s) || s >= 500) throw new Retry(`reply ${item.row.id.slice(0, 8)}: ${s}`);
        this.log(`Yui refused reply ${item.row.id.slice(0, 8)}: ${s} ${JSON.stringify(r)}`);
      }
      this.state.data.outbox.shift();
      this.state.data.acks.push(...item.ack);
      this.state.save();
      if (s < 300) await this.notify(item.row.id);
    }
  }

  async notify(messageId: string): Promise<void> {
    try {
      await http("POST", PUSH, { action: "notify", message_id: messageId, handoff: false },
                 { authorization: `Bearer ${this.ct}` }, 20, this.ua);
    } catch (e) {
      if (!(e instanceof Retry)) throw e;
    }
  }

  // -- phone to agent --

  async pending(aid: string): Promise<Row[]> {
    const floor = encodeURIComponent(this.state.data.floors[aid] ?? nowIso());
    const [s, r] = await this.rest("GET", "yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at"
      + `&agent_id=eq.${aid}&sender=eq.user&handled_at=is.null&created_at=gt.${floor}`
      + "&order=created_at.asc,id.asc&limit=200");
    if (s !== 200) throw new Retry(`read ${aid.slice(0, 8)}: ${s}`);
    const skip = new Set([...this.state.data.acks, ...(this.state.data.inflight[aid]?.turn ?? [])]);
    return (r as Row[]).filter((row) => !skip.has(row.id));
  }

  /** New rows for a turn, minus the ones an earlier run already answered. */
  async fresh(aid: string): Promise<Row[]> {
    const rows: Row[] = [];
    for (const row of await this.pending(aid)) {
      if (row.delivered_at && await this.answered(row)) {
        this.log(`${row.id.slice(0, 8)} was answered before a restart, not sending it again`);
        this.state.data.acks.push(row.id);
        this.state.save();
        continue;
      }
      rows.push(row);
    }
    return rows;
  }

  async rowsById(aid: string, ids: string[]): Promise<Row[]> {
    const [s, r] = await this.rest("GET", `yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at`
      + `&agent_id=eq.${aid}&id=in.(${ids.join(",")})&order=created_at.asc,id.asc`);
    if (s !== 200) throw new Retry(`read turn ${aid.slice(0, 8)}: ${s}`);
    return r;
  }

  // -- presence --

  /** A timer, not the turn loop, so a long turn never makes the agent look asleep. */
  startHeartbeat(): void {
    this.beat = setInterval(() => {
      this.beating = this.connect({ action: "heartbeat" }).catch((e) => this.log(`heartbeat: ${e.message}`));
    }, HEARTBEAT_SECONDS * 1000);
  }

  async stop(): Promise<void> {
    this.running = false;
    clearInterval(this.beat);
    await this.beating;
    try { // goodbye: the app shows the agent offline at once, not asleep
      await this.connect({ action: "bye" });
    } catch {}
  }
}
