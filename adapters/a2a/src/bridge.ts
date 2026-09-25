// The Yui side of the A2A bridge (INT-18, step 1: runs on your machine).
//
// Same relay rules as the webhook bridge (adapters/webhook, INT-2) and the
// Hermes plugin: rows in yui_messages are the contract (yuigui/spec/RELAY.md),
// every person's row is marked delivered when a turn starts and handled once
// its answer is written, replies name their rows in meta.turn, and anything
// that must survive a crash is on disk before it happens.
//
// What is A2A-specific:
//   - one Yui agent = one remote agent, found by its Agent Card;
//   - one Yui thread = one A2A context (contextId = the Yui agent id);
//   - each turn is one A2A message; the channel guide rides along as a context
//     part on the first message of every new task;
//   - while the task works, the app shows its working row (delivered, no
//     reply yet); the task's text parts become the reply when it settles;
//   - a task that asks for more (input-required) stays open, and the person's
//     next message continues it;
//   - the running task's id is on disk, so a restart picks the task back up
//     (SubscribeToTask, then GetTask) instead of sending the turn again.
//
// Node only (files, crypto). The protocol code in a2a.ts is runtime-neutral;
// the hosted step moves this loop into a Durable Object.
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname } from "node:path";
import {
  A2AClient, A2AError, A2AUnavailable, INTERRUPTED, TASK_NOT_FOUND, UNSUPPORTED_OPERATION, TaskView, isLangGraph,
  type AgentCard, type Message, type Part, type Update,
} from "./a2a.ts";

export const SUPABASE_URL = process.env.YUI_SUPABASE_URL ?? "https://ewzzaoperdpxqxkshynx.supabase.co";
const CONNECT = `${SUPABASE_URL}/functions/v1/yui-connect`;
const PUSH = `${SUPABASE_URL}/functions/v1/yui-push`;
const REST = `${SUPABASE_URL}/rest/v1`;
// Public client key (anon role only; it cannot read any yui_ table).
const PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS";
const UA = "yui-a2a/1";
const HEARTBEAT_SECONDS = 45;
const REFRESH_MARGIN_SECONDS = 600;
const BACKOFF_MAX = 60;
const POLL_MAX = 30;
const MAX_BODY = 32000;

const nowIso = () => new Date().toISOString();
const sleep = (s: number) => new Promise((r) => setTimeout(r, s * 1000));
export const log = (msg: string) => console.error(`${new Date().toTimeString().slice(0, 8)} yui-a2a: ${msg}`);

/** Yui said no for good (bad token, removed host): stop, don't retry. */
export class Refused extends Error {}
/** Network or server trouble on Yui's side: try again later. */
export class Retry extends Error {}

// -- state ------------------------------------------------------------------------------

/** A remote agent this machine serves, by the Yui agent's remote_ref. */
export interface Remote {
  card: string; // the Agent Card URL
  headers?: Record<string, string>; // e.g. authorization, for agents that want a key
  name?: string; // the card's name when it was paired
}

/** The turn in flight for one Yui agent. On disk before the message goes out. */
interface Inflight {
  turn: string[]; // the person's rows this turn answers
  messageId: string;
  taskId: string | null; // null until the agent names its task
  started: number;
}

interface StateData {
  token?: string;
  connector?: { id: string; name: string; kind?: string };
  floors: Record<string, string>;
  outbox: { row: any; ack: string[]; queued_at: number }[];
  acks: string[];
  remotes: Record<string, Remote>; // remote_ref -> card
  inflight: Record<string, Inflight>; // Yui agent id -> turn in flight
  open: Record<string, string>; // Yui agent id -> task waiting on the person
}

export class State {
  path: string;
  data: StateData;
  constructor(path: string) {
    this.path = path;
    let d: any = {};
    try {
      d = JSON.parse(readFileSync(path, "utf8"));
    } catch {}
    d.floors ??= {};
    d.outbox ??= [];
    d.acks ??= [];
    d.remotes ??= {};
    d.inflight ??= {};
    d.open ??= {};
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

async function http(method: string, url: string, body?: unknown, headers: Record<string, string> = {}, timeout = 20): Promise<[number, any]> {
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

export async function connectCall(body: Record<string, unknown>, token?: string): Promise<any> {
  const [s, r] = await http("POST", CONNECT, body, token ? { authorization: `Bearer ${token}` } : {});
  if (s === 401 || s === 403) throw new Refused(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  if (s >= 300) throw new Retry(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  return r ?? {};
}

/** A remote_ref from the card's name: "Currency Agent" -> "currency-agent". */
export function refFromName(name: string): string {
  const s = name.toLowerCase().replace(/[^a-z0-9_.-]+/g, "-").replace(/^[^a-z0-9]+|-+$/g, "").slice(0, 64);
  return s || "a2a";
}

export async function pair(state: State, code: string, ref: string, remote: Remote, hostName?: string): Promise<any> {
  const auth: Record<string, string> = state.data.token ? { authorization: `Bearer ${state.data.token}` } : {};
  const [s, r] = await http("POST", CONNECT, {
    action: "pair", code, remote_ref: ref, host_name: hostName ?? (hostname().split(".")[0] || "My computer"), kind: "http",
  }, auth);
  if (s !== 200) throw new Refused(`pair failed: ${r?.error ?? s}`);
  if (r.connector_token) { // a new connector (first pairing, or another Yui account)
    Object.assign(state.data, { token: r.connector_token, connector: r.connector, floors: {}, outbox: [], acks: [],
                                inflight: {}, open: {} });
  }
  state.data.remotes[ref] = remote;
  // Messages sent from the moment of pairing reach the agent, even before `run`.
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

/** Another remote agent on an already paired machine: a new Yui agent, no code. */
export async function add(state: State, ref: string, remote: Remote, name?: string): Promise<any> {
  if (!state.data.token) throw new Refused("not paired yet: run `pair <code> --card <url>` first");
  const r = await connectCall({ action: "add", remote_ref: ref, ...(name ? { name } : {}) }, state.data.token);
  state.data.remotes[ref] = remote;
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

// -- the bridge -------------------------------------------------------------------------------------

interface YuiAgent { id: string; name: string; handle?: string; remote_ref: string }
interface Row { id: string; agent_id: string; body: string; kind: string; meta: any; created_at: string; delivered_at: string | null }

export interface BridgeOptions {
  interval?: number; // seconds between reads
  guide?: boolean; // send the channel guide as a context part (default on)
  fetch?: typeof fetch; // for the A2A side only
}

export class Bridge {
  state: State;
  interval: number;
  sendGuide: boolean;
  a2aFetch?: typeof fetch;
  token: string | null = null;
  userId: string | null = null;
  tokenExp = 0;
  agents = new Map<string, YuiAgent>();
  guide = { version: "", body: "" };
  running = true;
  private jobs = new Map<string, Promise<void>>(); // one turn at a time per agent
  private retryAt = new Map<string, number>();
  private backoff = new Map<string, number>();
  private clients = new Map<string, { client: A2AClient; card: AgentCard; at: number }>();
  private beat?: ReturnType<typeof setInterval>;
  private beating?: Promise<unknown>;
  private flushing: Promise<void> = Promise.resolve();
  private fatal?: Error;

  constructor(state: State, opts: BridgeOptions = {}) {
    this.state = state;
    this.interval = opts.interval ?? 2;
    this.sendGuide = opts.guide ?? true;
    this.a2aFetch = opts.fetch;
  }

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code> --card <url>`");
    return this.state.data.token;
  }

  async session(): Promise<void> {
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
      const remote = this.state.data.remotes[a.remote_ref];
      log(remote ? `serving ${a.name} (${id.slice(0, 8)}) -> ${remote.card}` : `${a.name} (${a.remote_ref}) has no agent card on this machine; skipping it`);
    }
    this.agents = agents;
  }

  async ensureSession(): Promise<void> {
    if (!this.token || this.tokenExp - Date.now() / 1000 < REFRESH_MARGIN_SECONDS) await this.session();
  }

  async rest(method: string, path: string, body?: unknown, prefer?: string): Promise<[number, any]> {
    const headers = (): Record<string, string> => ({ authorization: `Bearer ${this.token}`, ...(prefer ? { prefer } : {}) });
    let [s, r] = await http(method, `${REST}/${path}`, body, headers());
    if (s === 401) {
      await this.session();
      [s, r] = await http(method, `${REST}/${path}`, body, headers());
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
        log(`Yui refused reply ${item.row.id.slice(0, 8)}: ${s} ${JSON.stringify(r)}`);
      }
      this.state.data.outbox.shift();
      this.state.data.acks.push(...item.ack);
      this.state.save();
      if (s < 300) await this.notify(item.row.id);
    }
  }

  async notify(messageId: string): Promise<void> {
    try {
      await http("POST", PUSH, { action: "notify", message_id: messageId, handoff: false }, { authorization: `Bearer ${this.ct}` });
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

  /** The A2A client for a Yui agent, from its card (re-read every 10 minutes). */
  async clientFor(agent: YuiAgent): Promise<{ client: A2AClient; card: AgentCard } | null> {
    const remote = this.state.data.remotes[agent.remote_ref];
    if (!remote) return null;
    const had = this.clients.get(agent.id);
    if (had && Date.now() - had.at < 600_000) return had;
    try {
      const { client, card } = await A2AClient.fromCard(remote.card, { headers: remote.headers, fetch: this.a2aFetch });
      const c = { client, card, at: Date.now() };
      if (!had) log(`${agent.name}: ${card.name}, A2A ${client.version}${card.streaming ? ", streaming" : ""} at ${client.url}`);
      this.clients.set(agent.id, c);
      return c;
    } catch (e) {
      if (had) return had; // keep the last good card while it is unreachable
      throw e;
    }
  }

  /** The A2A message for a turn: the person's words, plus the guide when a task starts.
   * A LangGraph server gets one text part and the rest as keyed data (state input keys). */
  message(agentId: string, rows: Row[], inflight: Inflight, taskId?: string, card?: AgentCard): Message {
    const parts: Part[] = [];
    const guide = !taskId && this.sendGuide && this.guide.body;
    const taps = rows.filter((r) => r.kind === "event" && r.meta);
    if (card && isLangGraph(card)) {
      parts.push({ text: rows.map((r) => r.body).join("\n") });
      const data: Record<string, unknown> = {};
      if (guide) data.yui_channel_guide = { version: this.guide.version, body: this.guide.body };
      if (taps.length) data.yui_events = taps.map((r) => ({ ...r.meta, row: r.id }));
      if (guide || taps.length) parts.push({ data, metadata: { yui: "context" } });
    } else {
      if (guide) parts.push({ text: this.guide.body, metadata: { yui: "channel_guide", version: this.guide.version } });
      parts.push({ text: rows.map((r) => r.body).join("\n") });
      for (const r of taps) parts.push({ data: r.meta, metadata: { yui: "event", row: r.id } }); // a tap, as data too
    }
    return { messageId: inflight.messageId, role: "user", parts, contextId: agentId, ...(taskId ? { taskId } : {}) };
  }

  tick(): void {
    for (const [aid, agent] of this.agents) {
      if (this.jobs.has(aid) || (this.retryAt.get(aid) ?? 0) > Date.now() / 1000) continue;
      if (!this.state.data.remotes[agent.remote_ref]) continue;
      const job = this.turn(agent).then(() => {
        this.backoff.delete(aid);
        this.retryAt.delete(aid);
      }, (e) => {
        if (e instanceof Refused) {
          this.fatal = e;
          return;
        }
        const wait = Math.min((this.backoff.get(aid) ?? 1) * 2, BACKOFF_MAX);
        this.backoff.set(aid, wait);
        this.retryAt.set(aid, Date.now() / 1000 + wait + Math.random());
        log(`${agent.name}: ${e?.message ?? e}; trying again in ${wait}s`);
      }).finally(() => this.jobs.delete(aid));
      this.jobs.set(aid, job);
    }
  }

  /** One turn for one agent: resume the one in flight, or start one from new rows. */
  async turn(agent: YuiAgent): Promise<void> {
    const aid = agent.id;
    const c = await this.clientFor(agent);
    if (!c) return;
    let inflight = this.state.data.inflight[aid];
    let rows: Row[] = [];
    if (!inflight) {
      for (const row of await this.pending(aid)) {
        if (row.delivered_at && await this.answered(row)) {
          log(`${row.id.slice(0, 8)} was answered before a restart, not sending it again`);
          this.state.data.acks.push(row.id);
          this.state.save();
          continue;
        }
        rows.push(row);
      }
      if (!rows.length) {
        await this.flushAcks();
        return;
      }
      const turn = rows.map((r) => r.id);
      // Same rows, same id: an agent that dedupes by messageId sees a resend once.
      const messageId = "yui-" + createHash("sha256").update(`${aid}:${turn.join(",")}`).digest("hex").slice(0, 32);
      inflight = { turn, messageId, taskId: null, started: Date.now() };
      this.state.data.inflight[aid] = inflight;
      this.state.save();
      await this.mark(turn, "delivered_at"); // the app's working row starts here
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
    } else if (inflight.taskId) {
      log(`${agent.name}: picking task ${inflight.taskId.slice(0, 8)} back up`);
    } else {
      rows = await this.rowsById(aid, inflight.turn); // crashed before the agent named a task: send again
      await this.mark(inflight.turn, "delivered_at"); // in case the crash came before the first mark
      log(`${agent.name}: sending ${inflight.turn.length} message(s) again (no task id before the restart)`);
    }

    const view = new TaskView();
    const onUpdate = (u: Update) => {
      view.apply(u);
      const id = view.task?.id;
      if (id && inflight!.taskId !== id) {
        inflight!.taskId = id;
        this.state.save(); // from here a restart resubscribes instead of resending
      }
    };
    if (!inflight.taskId) await this.start(aid, c, rows, inflight, onUpdate);
    if (!view.settled && inflight.taskId) {
      try {
        await this.follow(c.client, inflight.taskId, onUpdate);
      } catch (e) {
        if (!(e instanceof A2AError)) throw e;
        onUpdate(failed(`It lost track of that task (${e.message}).`));
      }
    }
    if (!view.settled) {
      if (!this.running) return; // stopping: the task id is on disk, the next run picks it up
      throw new Error(`task ${inflight.taskId?.slice(0, 8) ?? "(none)"} ended the stream still ${view.state ?? "unnamed"}`);
    }

    const state = view.state;
    const name = c.card.name;
    let text = view.text().trim();
    if (state && INTERRUPTED.has(state)) {
      this.state.data.open[aid] = view.task!.id; // the next message continues this task
      if (state === "auth-required") text = `${name} needs you to sign in before it can go on.${text ? `\n\n${text}` : ""}`;
      else if (!text) text = `${name} needs more from you to go on.`;
    } else {
      delete this.state.data.open[aid];
      if (state === "failed" || state === "rejected" || state === "canceled") {
        const what = state === "rejected" ? "turned that down" : state === "canceled" ? "stopped that task" : "couldn't finish that";
        text = `${name} ${what}.${text ? `\n\n${text}` : ""}`;
      }
    }
    log(`${agent.name}: task ${state ?? "answered"}${view.task ? ` (${view.task.id.slice(0, 8)})` : ""}, ${text.length} chars`);
    if (text) {
      this.queueReply(aid, text, inflight.turn);
    } else { // nothing to say: the turn is done
      delete this.state.data.inflight[aid];
      this.state.data.acks.push(...inflight.turn);
      this.state.save();
    }
    await this.flushOutbox();
    await this.flushAcks();
  }

  async rowsById(aid: string, ids: string[]): Promise<Row[]> {
    const [s, r] = await this.rest("GET", `yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at`
      + `&agent_id=eq.${aid}&id=in.(${ids.join(",")})&order=created_at.asc,id.asc`);
    if (s !== 200) throw new Retry(`read turn ${aid.slice(0, 8)}: ${s}`);
    return r;
  }

  /** Sends the turn. Streams when the agent can; otherwise sends and lets follow() poll. */
  async start(aid: string, c: { client: A2AClient; card: AgentCard }, rows: Row[], inflight: Inflight,
              onUpdate: (u: Update) => void): Promise<void> {
    let openTask: string | undefined = this.state.data.open[aid];
    for (let attempt = 0; ; attempt++) {
      const msg = this.message(aid, rows, inflight, openTask, c.card);
      try {
        if (c.card.streaming) {
          for await (const u of c.client.stream(msg)) onUpdate(u);
        } else {
          onUpdate(await c.client.send(msg, { returnImmediately: true }));
        }
        return;
      } catch (e) {
        // The open task is gone or over: start a fresh one with the same words.
        if (e instanceof A2AError && openTask && attempt === 0 && [TASK_NOT_FOUND, UNSUPPORTED_OPERATION].includes(e.code)) {
          log(`task ${openTask.slice(0, 8)} can't take more (${e.message}); starting a new one`);
          delete this.state.data.open[aid];
          openTask = undefined;
          continue;
        }
        if (e instanceof A2AUnavailable && inflight.taskId) {
          log(`stream dropped (${e.message}); following task ${inflight.taskId.slice(0, 8)}`);
          return; // follow() takes it from here
        }
        if (e instanceof A2AError) { // the agent said no: tell the person, don't loop
          onUpdate(failed(`It answered with an error: ${e.message}`));
          return;
        }
        throw e; // unreachable: back off and send again (same messageId)
      }
    }
  }

  /** Until the task settles: SubscribeToTask while it works, GetTask when streams won't. */
  async follow(client: A2AClient, taskId: string, onUpdate: (u: Update) => void): Promise<void> {
    const view = new TaskView();
    const apply = (u: Update) => { view.apply(u); onUpdate(u); };
    let wait = 1;
    let streams = true;
    while (this.running) {
      if (streams) {
        try {
          for await (const u of client.subscribe(taskId)) apply(u);
          if (view.settled) return;
        } catch (e) {
          if (e instanceof A2AError) {
            if (e.code === TASK_NOT_FOUND) throw new A2AFatal(e.message);
            streams = false; // over already, or no streaming: ask for it instead
          } else {
            log(`${(e as Error).message}; asking for task ${taskId.slice(0, 8)} instead`);
          }
        }
      }
      try {
        const task = await client.getTask(taskId);
        apply({ kind: "task", task });
        if (view.settled) return;
      } catch (e) {
        if (e instanceof A2AError && e.code === TASK_NOT_FOUND) throw new A2AFatal(e.message);
        if (!(e instanceof A2AUnavailable)) throw e;
      }
      await sleep(wait);
      wait = Math.min(wait * 2, POLL_MAX);
    }
  }

  async run(): Promise<void> {
    await this.session();
    log(`online as ${this.state.data.connector?.name}; guide ${this.guide?.version}`);
    // A timer, not the turn loop, so a long task never makes the agent look asleep.
    this.beat = setInterval(() => {
      this.beating = connectCall({ action: "heartbeat" }, this.ct).catch((e) => log(`heartbeat: ${e.message}`));
    }, HEARTBEAT_SECONDS * 1000);
    let backoff = 1;
    while (this.running) {
      try {
        if (this.fatal) throw this.fatal;
        await this.ensureSession();
        await this.flushOutbox();
        await this.flushAcks();
        this.tick();
        backoff = 1;
        await sleep(this.interval);
      } catch (e) {
        if (!(e instanceof Retry)) throw e;
        log(`${e.message}; retrying in ${backoff}s`);
        await sleep(backoff + Math.random());
        backoff = Math.min(backoff * 2, BACKOFF_MAX);
      }
    }
  }

  async stop(): Promise<void> {
    this.running = false;
    clearInterval(this.beat);
    await this.beating;
    try { // goodbye: the app shows the agent offline at once, not asleep
      await connectCall({ action: "bye" }, this.ct);
    } catch {}
  }
}

/** A made-up final status, for the times Yui has to end the turn itself. */
function failed(text: string): Update {
  return { kind: "status", taskId: "", state: "failed", final: true,
           message: { messageId: "", role: "agent", parts: [{ text }] } };
}

/** The remote agent lost the task: say so once instead of retrying forever. */
class A2AFatal extends A2AError {
  constructor(message: string) {
    super(0, message);
  }
}
