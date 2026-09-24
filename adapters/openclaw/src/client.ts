// Yui connector client for OpenClaw (INT-1).
//
// Spec: yuigui/spec/RELAY.md (rows, acks, meta.turn) and spec/AGENTS.md
// (connectors). Ported from the webhook bridge (adapters/webhook/node), which
// speaks the same contract: dial out, trade the connector token for a session,
// read the person's rows with handled_at null, write agent rows with meta.turn,
// delivered/handled acks, a reply outbox on disk, bye on a clean stop.
// No dependencies beyond Node 22.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname } from "node:path";

const SUPABASE_URL = process.env.YUI_SUPABASE_URL ?? "https://ewzzaoperdpxqxkshynx.supabase.co";
const CONNECT = `${SUPABASE_URL}/functions/v1/yui-connect`;
const PUSH = `${SUPABASE_URL}/functions/v1/yui-push`;
const REST = `${SUPABASE_URL}/rest/v1`;
// Public client key (anon role only; it cannot read any yui_ table).
const PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS";
const UA = "yui-openclaw/1";
export const HEARTBEAT_SECONDS = 45;
const REFRESH_MARGIN_SECONDS = 600; // the 60-minute session is renewed 10 minutes early
export const BACKOFF_MAX = 60;
const MAX_BODY = 32000;

const nowIso = () => new Date().toISOString();
export const sleep = (s: number, signal?: AbortSignal) =>
  new Promise<void>((resolve) => {
    const t = setTimeout(resolve, s * 1000);
    signal?.addEventListener("abort", () => { clearTimeout(t); resolve(); }, { once: true });
  });

/** Yui said no for good (bad token, removed host): stop, don't retry. */
export class Refused extends Error {}
/** Network or server trouble: try again later. */
export class Retry extends Error {}

export type YuiAgent = { id: string; name: string; handle?: string; remote_ref?: string };
export type YuiRow = {
  id: string; agent_id: string; body: string; kind: "text" | "event";
  meta: Record<string, unknown> | null; created_at: string; delivered_at: string | null;
};
type OutboxItem = { row: Record<string, unknown> & { id: string; meta?: { turn?: string[] } };
                    ack: string[]; handoff: boolean; queued_at: number };
type StateData = {
  token?: string; connector?: { id: string; name: string; kind: string };
  floors: Record<string, string>; outbox: OutboxItem[]; acks: string[];
};

// -- state ---------------------------------------------------------------------

/** The connector token, a floor per agent, the reply outbox. Mode 600. */
export class State {
  data: StateData;
  constructor(readonly path: string) {
    let data: Partial<StateData> = {};
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {}
    this.data = { floors: {}, outbox: [], acks: [], ...data } as StateData;
  }
  save() {
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const tmp = this.path.replace(/\.json$/, "") + ".tmp";
    writeFileSync(tmp, JSON.stringify(this.data, null, 1), { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}

// -- HTTP ------------------------------------------------------------------------

async function http(method: string, url: string, body?: unknown, headers: Record<string, string> = {},
                    timeout = 20): Promise<[number, any]> {
  let r: Response;
  try {
    r = await fetch(url, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "content-type": "application/json", apikey: PUBLISHABLE, "user-agent": UA, ...headers },
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

export async function connectCall(body: Record<string, unknown>, token?: string) {
  const [s, r] = await http("POST", CONNECT, body, token ? { authorization: `Bearer ${token}` } : {});
  if (s === 401 || s === 403) throw new Refused(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  if (s >= 300) throw new Retry(`yui-connect ${body.action}: ${s}`);
  return r ?? {};
}

// -- pairing ------------------------------------------------------------------------

/** Claim the 6-digit code from the app's Add agent. `ref` is the OpenClaw agent id. */
export async function pair(state: State, code: string, ref: string, name?: string) {
  const auth: Record<string, string> = state.data.token ? { authorization: `Bearer ${state.data.token}` } : {};
  const [s, r] = await http("POST", CONNECT, {
    action: "pair", code, remote_ref: ref, host_name: name ?? (hostname().split(".")[0] || "My computer"),
    kind: "openclaw",
  }, auth);
  if (s !== 200) throw new Refused(`pair failed: ${r?.error ?? s}`);
  if (r.connector_token) { // a new connector (first pairing, or another Yui account)
    Object.assign(state.data, { token: r.connector_token, connector: r.connector, floors: {}, outbox: [], acks: [] });
  }
  // Messages sent from the moment of pairing reach the agent, even before the gateway starts.
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r as { agent: YuiAgent; connector: { id: string; name: string } };
}

export async function fetchGuide(): Promise<{ version: string; body: string }> {
  return (await connectCall({ action: "guide" })).guide ?? { version: "", body: "" };
}

// -- the connector -------------------------------------------------------------------

export type Log = (msg: string) => void;
/** Runs one turn on the agent. Returns the replies (maybe none), or null to try again later. */
export type Respond = (agent: YuiAgent, rows: YuiRow[]) => Promise<string[] | null>;

export class Connector {
  token: string | null = null;
  userId: string | null = null;
  tokenExp = 0;
  agents = new Map<string, YuiAgent>();
  guide = { version: "", body: "" };
  private retryAt = new Map<string, number>(); // agent id -> time its failed turn may run again
  private backoff = new Map<string, number>();
  private beat?: ReturnType<typeof setInterval>;
  private beating?: Promise<unknown>;

  constructor(readonly state: State, readonly log: Log = () => {}) {}

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `openclaw yui pair <code>`");
    return this.state.data.token;
  }

  async session() {
    const r = await connectCall({ action: "session" }, this.ct);
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
      this.log(`serving ${a.name} (${id.slice(0, 8)}) as OpenClaw agent ${a.remote_ref}`);
    }
    this.agents = agents;
  }

  async ensureSession() {
    if (!this.token || this.tokenExp - Date.now() / 1000 < REFRESH_MARGIN_SECONDS) await this.session();
  }

  async rest(method: string, path: string, body?: unknown, prefer?: string): Promise<[number, any]> {
    const headers = (): Record<string, string> => ({ authorization: `Bearer ${this.token}`, ...(prefer ? { prefer } : {}) });
    let [s, r] = await http(method, `${REST}/${path}`, body, headers());
    if (s === 401) { // token expired under us: one fresh session, one more try
      await this.session();
      [s, r] = await http(method, `${REST}/${path}`, body, headers());
    }
    return [s, r];
  }

  // -- acks (RELAY.md, Delivery) --

  async mark(ids: string[], column: "delivered_at" | "handled_at") {
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

  async flushAcks() {
    const ids = [...this.state.data.acks];
    if (ids.length && await this.mark(ids, "handled_at")) {
      this.state.data.acks = this.state.data.acks.filter((i) => !ids.includes(i));
      this.state.save();
    }
  }

  /** An earlier run already answered this row: a reply names it in meta.turn,
   *  written or still waiting in the outbox. */
  async answered(row: YuiRow) {
    if (this.state.data.outbox.some((i) => (i.row.meta?.turn ?? []).includes(row.id))) return true;
    const [s, r] = await this.rest("GET", `yui_messages?select=id&agent_id=eq.${row.agent_id}&sender=eq.agent`
      + `&meta->turn=cs.${encodeURIComponent(JSON.stringify([row.id]))}&limit=1`);
    return s === 200 && r.length > 0;
  }

  // -- agent to phone --

  queueReply(agentId: string, text: string, turn: string[] | null, ack: string[] | null, handoff = false) {
    const row: OutboxItem["row"] = { id: randomUUID(), user_id: this.userId, agent_id: agentId, sender: "agent",
                                     kind: "text", body: text.trim().slice(0, MAX_BODY) };
    if (turn) row.meta = { turn }; // the rows this reply answers (restart dedupe)
    this.state.data.outbox.push({ row, ack: ack ?? [], handoff, queued_at: Date.now() / 1000 });
    this.state.save(); // on disk before the first try: a crash now still sends it
    return row.id;
  }

  /** Oldest first; a reply that can't go yet holds the ones behind it. */
  async flushOutbox() {
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
      if (s < 300) await this.notify(item.row.id, item.handoff);
    }
  }

  /** Buzz the phone (yui-push skips it when the thread is already open). */
  async notify(messageId: string, handoff: boolean) {
    try {
      await http("POST", PUSH, { action: "notify", message_id: messageId, handoff }, { authorization: `Bearer ${this.ct}` });
    } catch (e) {
      if (!(e instanceof Retry)) throw e;
    }
  }

  /** A message the agent starts on its own (cron, the message tool): no turn, a push. */
  async send(agentId: string, text: string) {
    const id = this.queueReply(agentId, text, null, null, true);
    try {
      await this.flushOutbox();
    } catch (e) {
      if (!(e instanceof Retry)) throw e;
      this.log(`${e.message}; it waits in the outbox and goes out with the next run`);
    }
    return id;
  }

  // -- phone to agent --

  async fetchPending(aid: string): Promise<YuiRow[]> {
    const floor = encodeURIComponent(this.state.data.floors[aid] ?? nowIso());
    const [s, r] = await this.rest("GET", "yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at"
      + `&agent_id=eq.${aid}&sender=eq.user&handled_at=is.null&created_at=gt.${floor}`
      + "&order=created_at.asc,id.asc&limit=200");
    if (s !== 200) throw new Retry(`read ${aid.slice(0, 8)}: ${s}`);
    const pending = new Set(this.state.data.acks);
    return (r as YuiRow[]).filter((row) => !pending.has(row.id));
  }

  /** One turn per agent at a time; whatever arrived meanwhile folds into the next one. */
  async runTurns(respond: Respond) {
    for (const [aid, agent] of this.agents) {
      if ((this.retryAt.get(aid) ?? 0) > Date.now() / 1000) continue;
      const rows: YuiRow[] = [];
      for (const row of await this.fetchPending(aid)) {
        if (row.delivered_at && await this.answered(row)) {
          this.log(`${row.id.slice(0, 8)} was answered before a restart, not sending it again`);
          this.state.data.acks.push(row.id);
          this.state.save();
          continue;
        }
        rows.push(row);
      }
      if (!rows.length) continue;
      const ids = rows.map((r) => r.id);
      await this.mark(ids, "delivered_at");
      this.log(`turn for ${agent.name}: ${rows.length} message(s)`);
      let replies: string[] | null;
      try {
        replies = await respond(agent, rows);
      } catch (e: any) {
        this.log(`agent turn failed (${e?.message ?? e}); trying it again later`);
        replies = null;
      }
      if (replies === null) {
        const wait = Math.min((this.backoff.get(aid) ?? 1) * 2, BACKOFF_MAX);
        this.backoff.set(aid, wait);
        this.retryAt.set(aid, Date.now() / 1000 + wait + Math.random());
        continue;
      }
      this.backoff.delete(aid);
      this.retryAt.delete(aid);
      if (!replies.length) {
        this.state.data.acks.push(...ids);
        this.state.save();
      }
      replies.forEach((text, n) => this.queueReply(aid, text, ids, n === replies!.length - 1 ? ids : null));
      await this.flushOutbox();
      await this.flushAcks();
    }
  }

  /** The loop: until `signal` aborts, then a goodbye so the app shows offline at once. */
  async run(respond: Respond, signal: AbortSignal, interval = 2) {
    await this.session();
    this.log(`online as ${this.state.data.connector?.name}; guide ${this.guide?.version}`);
    // A timer, not the turn loop, so a long agent turn never makes the agent look asleep.
    this.beat = setInterval(() => {
      this.beating = connectCall({ action: "heartbeat" }, this.ct).catch((e) => this.log(`heartbeat: ${e.message}`));
    }, HEARTBEAT_SECONDS * 1000);
    let backoff = 1;
    try {
      while (!signal.aborted) {
        try {
          await this.ensureSession();
          await this.flushOutbox();
          await this.flushAcks();
          await this.runTurns(respond);
          backoff = 1;
          await sleep(interval, signal);
        } catch (e: any) {
          if (!(e instanceof Retry)) throw e;
          this.log(`${e.message}; retrying in ${backoff}s`);
          await sleep(backoff + Math.random(), signal);
          backoff = Math.min(backoff * 2, BACKOFF_MAX);
        }
      }
    } finally {
      await this.stop();
    }
  }

  async stop() {
    clearInterval(this.beat);
    await this.beating; // a beat in flight must not land after the goodbye
    try {
      await connectCall({ action: "bye" }, this.ct);
      this.log("offline (bye sent)");
    } catch {}
  }
}

export function pickAgent(agents: Map<string, YuiAgent>, want?: string | null) {
  const all = [...agents.values()];
  if (!want) return all[0] ?? null;
  const w = want.toLowerCase().replace(/^yui:/, "");
  return all.find((a) => (["id", "handle", "remote_ref", "name"] as const)
    .some((k) => String(a[k] ?? "").toLowerCase() === w)) ?? null;
}
