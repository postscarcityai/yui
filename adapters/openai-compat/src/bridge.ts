// The Yui side of the model bridge (INT-12, step 1: runs on your machine).
//
// Same relay rules as the webhook bridge (adapters/webhook, INT-2) and the A2A
// bridge (adapters/a2a, INT-18): rows in yui_messages are the contract
// (yuigui/spec/RELAY.md), every person's row is marked delivered when a turn
// starts and handled once its answer is written, replies name their rows in
// meta.turn, and anything that must survive a crash is on disk before it
// happens.
//
// What is model-specific:
//   - one Yui agent = one model on one OpenAI-compatible server (base URL,
//     model, optional key);
//   - a chat API remembers nothing, so Yui holds the thread: each turn sends
//     the channel guide as the system message, the thread's newest rows that
//     fit the model's context, then the person's new messages;
//   - while the model answers, the app shows its working row (delivered, no
//     reply yet); the answer lands whole when it is done;
//   - the turn in flight is on disk, so a restart asks the model again for
//     that turn (the only case it hears a turn twice) and writes one answer.
//
// Node only (files, env). The model code in openai.ts and thread.ts is
// runtime-neutral; the hosted step moves this loop into a Durable Object.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname } from "node:path";
import { ChatClient, ModelError, ModelUnavailable, StreamRefused, type Completion } from "./openai.ts";
import { buildMessages, type ThreadRow } from "./thread.ts";

export const SUPABASE_URL = process.env.YUI_SUPABASE_URL ?? "https://ewzzaoperdpxqxkshynx.supabase.co";
const CONNECT = `${SUPABASE_URL}/functions/v1/yui-connect`;
const PUSH = `${SUPABASE_URL}/functions/v1/yui-push`;
const REST = `${SUPABASE_URL}/rest/v1`;
// Public client key (anon role only; it cannot read any yui_ table).
const PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS";
const UA = "yui-openai/1";
const HEARTBEAT_SECONDS = 45;
const REFRESH_MARGIN_SECONDS = 600;
const BACKOFF_MAX = 60;
const HISTORY_ROWS = 60;
// The model has been unreachable this long: tell the person once (the tests shorten it).
const WAIT_NOTE_SECONDS = Number(process.env.YUI_OPENAI_WAIT_NOTE ?? 90);
const MAX_BODY = 32000;

const nowIso = () => new Date().toISOString();
const sleep = (s: number) => new Promise((r) => setTimeout(r, s * 1000));
export const log = (msg: string) => console.error(`${new Date().toTimeString().slice(0, 8)} yui-openai: ${msg}`);

/** Yui said no for good (bad token, removed host): stop, don't retry. */
export class Refused extends Error {}
/** Network or server trouble on Yui's side: try again later. */
export class Retry extends Error {}

// -- state ------------------------------------------------------------------------------

/** A model this machine serves, by the Yui agent's remote_ref. */
export interface Remote {
  url: string; // the server's base URL, ".../v1"
  model: string;
  keyEnv?: string; // the key is read from this environment variable at run time
  key?: string; // or kept here (the file is mode 600), from --key-stdin
  system?: string; // the person's own instructions, before the channel guide
  context?: number; // the model's context window in tokens
  maxTokens?: number;
  temperature?: number;
  stream?: boolean; // false: never stream (set by --no-stream, or learned when a server refuses)
}

/** The turn in flight for one Yui agent. On disk before the model is asked. */
interface Inflight {
  turn: string[]; // the person's rows this turn answers
  started: number;
  tries: number;
  noted?: boolean; // the "can't reach the model" line went out for this turn
}

interface StateData {
  token?: string;
  connector?: { id: string; name: string; kind?: string };
  floors: Record<string, string>;
  outbox: { row: any; ack: string[]; queued_at: number }[];
  acks: string[];
  remotes: Record<string, Remote>; // remote_ref -> model
  inflight: Record<string, Inflight>; // Yui agent id -> turn in flight
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
    this.data = d;
  }
  save(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = this.path.replace(/\.json$/, "") + ".tmp";
    writeFileSync(tmp, JSON.stringify(this.data, null, 1), { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}

/** The key for a model: its environment variable, else the one kept in the state file. */
export function keyFor(remote: Remote): string | undefined {
  if (remote.keyEnv) {
    const k = process.env[remote.keyEnv];
    if (!k) throw new Refused(`${remote.keyEnv} is not set; the model's key is read from it`);
    return k;
  }
  return remote.key || undefined;
}

export function clientFor(remote: Remote, fetchImpl?: typeof fetch): ChatClient {
  return new ChatClient(remote.url, { key: keyFor(remote), fetch: fetchImpl });
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

/** A remote_ref from the model's name: "qwen2.5:7b" -> "qwen2.5-7b". */
export function refFromName(name: string): string {
  const s = name.toLowerCase().replace(/[^a-z0-9_.-]+/g, "-").replace(/^[^a-z0-9]+|-+$/g, "").slice(0, 64);
  return s || "model";
}

export async function pair(state: State, code: string, ref: string, remote: Remote, hostName?: string): Promise<any> {
  const auth: Record<string, string> = state.data.token ? { authorization: `Bearer ${state.data.token}` } : {};
  const [s, r] = await http("POST", CONNECT, {
    action: "pair", code, remote_ref: ref, host_name: hostName ?? (hostname().split(".")[0] || "My computer"), kind: "http",
  }, auth);
  if (s !== 200) throw new Refused(`pair failed: ${r?.error ?? s}`);
  if (r.connector_token) { // a new connector (first pairing, or another Yui account)
    Object.assign(state.data, { token: r.connector_token, connector: r.connector, floors: {}, outbox: [], acks: [], inflight: {} });
  }
  state.data.remotes[ref] = remote;
  // Messages sent from the moment of pairing reach the model, even before `run`.
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

/** Another model on an already paired machine: a new Yui agent, no code. */
export async function add(state: State, ref: string, remote: Remote, name?: string): Promise<any> {
  if (!state.data.token) throw new Refused("not paired yet: run `pair <code> --model <name>` first");
  const r = await connectCall({ action: "add", remote_ref: ref, ...(name ? { name } : {}) }, state.data.token);
  state.data.remotes[ref] = remote;
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

// -- the bridge -------------------------------------------------------------------------------------

interface YuiAgent { id: string; name: string; handle?: string; remote_ref: string }
interface Row extends ThreadRow { agent_id: string; created_at: string; delivered_at: string | null }

export interface BridgeOptions {
  interval?: number; // seconds between reads
  fetch?: typeof fetch; // for the model side only
}

export class Bridge {
  state: State;
  interval: number;
  modelFetch?: typeof fetch;
  token: string | null = null;
  userId: string | null = null;
  tokenExp = 0;
  agents = new Map<string, YuiAgent>();
  guide = { version: "", body: "" };
  running = true;
  private jobs = new Map<string, Promise<void>>(); // one turn at a time per agent
  private retryAt = new Map<string, number>();
  private backoff = new Map<string, number>();
  private beat?: ReturnType<typeof setInterval>;
  private beating?: Promise<unknown>;
  private flushing: Promise<void> = Promise.resolve();
  private fatal?: Error;

  constructor(state: State, opts: BridgeOptions = {}) {
    this.state = state;
    this.interval = opts.interval ?? 2;
    this.modelFetch = opts.fetch;
  }

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code> --model <name>`");
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
      const m = this.state.data.remotes[a.remote_ref];
      log(m ? `serving ${a.name} (${id.slice(0, 8)}) -> ${m.model} at ${m.url}` : `${a.name} (${a.remote_ref}) has no model on this machine; skipping it`);
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
  async answered(agentId: string, rowId: string): Promise<boolean> {
    if (this.state.data.outbox.some((i) => (i.row.meta?.turn ?? []).includes(rowId))) return true;
    const [s, r] = await this.rest("GET", `yui_messages?select=id&agent_id=eq.${agentId}&sender=eq.agent`
      + `&meta->turn=cs.${encodeURIComponent(JSON.stringify([rowId]))}&limit=1`);
    if (s !== 200) throw new Retry(`check answered ${rowId.slice(0, 8)}: ${s}`);
    return r.length > 0;
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

  /** A line from the bridge itself that answers nothing: the turn stays open. */
  queueNote(agentId: string, text: string): void {
    const row = { id: randomUUID(), user_id: this.userId, agent_id: agentId, sender: "agent", kind: "text",
                  body: text, meta: { bridge: "status" } };
    this.state.data.outbox.push({ row, ack: [], queued_at: Date.now() / 1000 });
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
    const [s, r] = await this.rest("GET", "yui_messages?select=id,agent_id,sender,body,kind,meta,created_at,delivered_at"
      + `&agent_id=eq.${aid}&sender=eq.user&handled_at=is.null&created_at=gt.${floor}`
      + "&order=created_at.asc,id.asc&limit=200");
    if (s !== 200) throw new Retry(`read ${aid.slice(0, 8)}: ${s}`);
    const skip = new Set(this.state.data.acks);
    return (r as Row[]).filter((row) => !skip.has(row.id));
  }

  async rowsById(aid: string, ids: string[]): Promise<Row[]> {
    const [s, r] = await this.rest("GET", "yui_messages?select=id,agent_id,sender,body,kind,meta,created_at,delivered_at"
      + `&agent_id=eq.${aid}&id=in.(${ids.join(",")})&order=created_at.asc,id.asc`);
    if (s !== 200) throw new Retry(`read turn ${aid.slice(0, 8)}: ${s}`);
    return r;
  }

  /** The thread before this turn, oldest first: what Yui remembers for the model. */
  async history(aid: string, before: Row): Promise<ThreadRow[]> {
    const [s, r] = await this.rest("GET", "yui_messages?select=id,sender,body,kind,meta,created_at"
      + `&agent_id=eq.${aid}&created_at=lt.${encodeURIComponent(before.created_at)}`
      + `&order=created_at.desc,id.desc&limit=${HISTORY_ROWS}`);
    if (s !== 200) throw new Retry(`read thread ${aid.slice(0, 8)}: ${s}`);
    return (r as ThreadRow[]).reverse();
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
        // A server's Retry-After (429 from Meta, OpenAI) beats our own guess.
        const wait = Math.max(Math.min((this.backoff.get(aid) ?? 1) * 2, BACKOFF_MAX), e?.retryAfter ?? 0);
        this.backoff.set(aid, Math.min(wait, BACKOFF_MAX));
        this.retryAt.set(aid, Date.now() / 1000 + wait + Math.random());
        log(`${agent.name}: ${e?.message ?? e}; trying again in ${wait}s`);
      }).finally(() => this.jobs.delete(aid));
      this.jobs.set(aid, job);
    }
  }

  /** One turn for one agent: finish the one in flight, or start one from new rows. */
  async turn(agent: YuiAgent): Promise<void> {
    const aid = agent.id;
    const remote = this.state.data.remotes[agent.remote_ref];
    let inflight = this.state.data.inflight[aid];
    let rows: Row[] = [];
    if (inflight) {
      // A crash between writing the answer and clearing the turn: only mark it done.
      if (await this.answered(aid, inflight.turn[inflight.turn.length - 1])) {
        log(`${agent.name}: that turn was answered before a restart, not asking again`);
        delete this.state.data.inflight[aid];
        this.state.data.acks.push(...inflight.turn);
        this.state.save();
        await this.flushAcks();
        return;
      }
      rows = await this.rowsById(aid, inflight.turn);
      if (inflight.tries === 0) log(`${agent.name}: asking again for ${rows.length} message(s) (the bridge stopped mid-turn)`);
    } else {
      for (const row of await this.pending(aid)) {
        if (row.delivered_at && await this.answered(aid, row.id)) {
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
      inflight = { turn: rows.map((r) => r.id), started: Date.now(), tries: 0 };
      this.state.data.inflight[aid] = inflight;
      this.state.save();
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
    }
    if (!rows.length) { // the rows are gone (thread cleared): drop the turn
      delete this.state.data.inflight[aid];
      this.state.save();
      return;
    }
    await this.mark(inflight.turn, "delivered_at"); // the app's working row starts here

    const history = (await this.history(aid, rows[0])).filter((r) => !inflight!.turn.includes(r.id));
    const { messages, dropped, over } = buildMessages(history, rows, {
      guide: this.guide.body, system: remote.system, context: remote.context, reserve: remote.maxTokens,
    });
    if (over) log(`${agent.name}: the guide and this turn alone are over ${remote.context ?? 4096} tokens; raise --context (and the server's)`);
    else if (dropped) log(`${agent.name}: ${dropped} older message(s) left out to fit ${remote.context ?? 4096} tokens`);

    let text: string;
    try {
      const done = await this.ask(remote, {
        model: remote.model, messages,
        ...(remote.temperature !== undefined ? { temperature: remote.temperature } : {}),
        ...(remote.maxTokens ? { max_tokens: remote.maxTokens } : {}),
      });
      text = done.text;
      log(`${agent.name}: ${remote.model} answered${done.streamed ? " (streamed)" : ""}, ${text.length} chars`
        + (done.finish && done.finish !== "stop" ? `, finish ${done.finish}` : "")
        + (done.usage?.prompt_tokens ? `, ${done.usage.prompt_tokens} prompt tokens` : ""));
      if (!text && done.finish === "length") text = `${agent.name} ran out of room before it could answer. Try a shorter message, or raise its max tokens.`;
      // Gemini ends a blocked answer with no text and content_filter (or SAFETY / RECITATION).
      if (!text && /content_filter|safety|recitation|prohibited|blocklist/i.test(done.finish ?? "")) {
        text = `${agent.name}'s model stopped before answering (its ${done.finish} filter). Try saying it another way.`;
      }
    } catch (e) {
      if (e instanceof ModelUnavailable) {
        inflight.tries += 1;
        this.state.save();
        if (!inflight.noted && Date.now() - inflight.started > WAIT_NOTE_SECONDS * 1000) {
          inflight.noted = true;
          this.queueNote(aid, `${agent.name} can't reach its model right now (${e.message}). Your message waits and goes the moment it's back.`);
          await this.flushOutbox();
        }
        throw e; // back off, keep the turn, ask again
      }
      if (!(e instanceof ModelError)) throw e;
      text = `${agent.name} couldn't answer: ${e.message}`; // the server said no: say why once, don't loop
      log(`${agent.name}: ${e.message}`);
    }
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

  /** Streams when the server can; a server that refuses streams is asked plain from then on. */
  async ask(remote: Remote, req: Parameters<ChatClient["complete"]>[0]): Promise<Completion> {
    const client = clientFor(remote, this.modelFetch);
    try {
      return await client.complete(req, { stream: remote.stream !== false });
    } catch (e) {
      if (!(e instanceof StreamRefused)) throw e;
      log(`${remote.url} does not stream (${e.message}); asking plain from now on`);
      remote.stream = false;
      this.state.save();
      return await client.complete(req, { stream: false });
    }
  }

  async run(): Promise<void> {
    await this.session();
    log(`online as ${this.state.data.connector?.name}; guide ${this.guide?.version}`);
    // A timer, not the turn loop, so a slow model never makes the agent look asleep.
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
    await this.flushAcks().catch(() => {}); // an answer that just landed is marked handled now, not next run
    try { // goodbye: the app shows the agent offline at once, not asleep
      await connectCall({ action: "bye" }, this.ct);
    } catch {}
  }
}
