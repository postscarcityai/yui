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
//     (SubscribeToTask, then GetTask) instead of sending the turn again;
//   - tables (YUI-171): table words in the answer go through Yui's one tables
//     call before the answer is saved, and a data part {"yui": "tables",
//     "lines": ...} runs its lines, the rows coming back as a data part.
//
// Node only (files, crypto). The protocol code in a2a.ts is runtime-neutral;
// the hosted step moves this loop into a Durable Object.
import { createHash } from "node:crypto";
import {
  A2AClient, A2AError, A2AUnavailable, INTERRUPTED, TASK_NOT_FOUND, UNSUPPORTED_OPERATION, TaskView, isLangGraph,
  type AgentCard, type Message, type Part, type Update,
} from "./a2a.ts";
import {
  BACKOFF_MAX, Refused, Retry, State as RelayState, YuiRelay, addAgent, logger, pairConnector, refFromName as rf, sleep,
  type Inflight as RelayInflight, type Row, type StateData as RelayData, type YuiAgent,
} from "./relay.ts";

export { SUPABASE_URL, Refused, Retry, connectCall } from "./relay.ts";
const UA = "yui-a2a/1";
const POLL_MAX = 30;

export const log = logger("yui-a2a");
export const refFromName = (name: string) => rf(name, "a2a");

// -- state ------------------------------------------------------------------------------

/** A remote agent this machine serves, by the Yui agent's remote_ref. */
export interface Remote {
  card: string; // the Agent Card URL
  headers?: Record<string, string>; // e.g. authorization, for agents that want a key
  name?: string; // the card's name when it was paired
}

/** The turn in flight for one Yui agent. On disk before the message goes out. */
interface Inflight extends RelayInflight {
  taskId: string | null; // null until the agent names its task
  round?: number; // tables reads sent back this turn
  followup?: Part[]; // the rows sent back for a read, instead of the person's words
  tables?: Record<string, unknown>; // rows from the last answer's data part, riding on this message
}

interface StateData extends RelayData {
  remotes: Record<string, Remote>; // remote_ref -> card
  inflight: Record<string, Inflight>;
  open: Record<string, string>; // Yui agent id -> task waiting on the person
  tables: Record<string, Record<string, unknown>>; // Yui agent id -> rows for its next message
}

export class State extends RelayState<StateData> {
  constructor(path: string) {
    super(path, { remotes: {}, open: {}, tables: {} });
  }
}

/** An answer with table words in it (cheap: an ordinary answer makes no tables call). */
export const TABLE_WORDS = /^[ \t]*(?:table[ \t]+(?:create|drop)[ \t]|put[ \t]+[A-Za-z]|query[ \t]+[A-Za-z])|^```tables\b/m;
/** Reads sent back to the agent in one turn, like the native runtime. */
const READ_ROUNDS = 2;

export async function pair(state: State, code: string, ref: string, remote: Remote, hostName?: string): Promise<any> {
  const r = await pairConnector(state, code, ref, { hostName, kind: "http", reset: { open: {} }, ua: UA });
  state.data.remotes[ref] = remote;
  state.save();
  return r;
}

/** Another remote agent on an already paired machine: a new Yui agent, no code. */
export async function add(state: State, ref: string, remote: Remote, name?: string): Promise<any> {
  if (!state.data.token) throw new Refused("not paired yet: run `pair <code> --card <url>` first");
  const r = await addAgent(state, ref, name, UA);
  state.data.remotes[ref] = remote;
  state.save();
  return r;
}

// -- the bridge -------------------------------------------------------------------------------------

export interface BridgeOptions {
  interval?: number; // seconds between reads
  guide?: boolean; // send the channel guide as a context part (default on)
  fetch?: typeof fetch; // for the A2A side only
}

export class Bridge extends YuiRelay<StateData> {
  declare state: State;
  interval: number;
  sendGuide: boolean;
  a2aFetch?: typeof fetch;
  private jobs = new Map<string, Promise<void>>(); // one turn at a time per agent
  private retryAt = new Map<string, number>();
  private backoff = new Map<string, number>();
  private clients = new Map<string, { client: A2AClient; card: AgentCard; at: number }>();
  private fatal?: Error;

  constructor(state: State, opts: BridgeOptions = {}) {
    super(state, { ua: UA, log });
    this.interval = opts.interval ?? 2;
    this.sendGuide = opts.guide ?? true;
    this.a2aFetch = opts.fetch;
  }

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code> --card <url>`");
    return this.state.data.token;
  }

  protected onAgent(a: YuiAgent): void {
    const remote = this.state.data.remotes[a.remote_ref];
    log(remote ? `serving ${a.name} (${a.id.slice(0, 8)}) -> ${remote.card}` : `${a.name} (${a.remote_ref}) has no agent card on this machine; skipping it`);
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
    if (inflight.followup) {
      return { messageId: `${inflight.messageId}-t${inflight.round ?? 1}`, role: "user", parts: inflight.followup,
               contextId: agentId, ...(taskId ? { taskId } : {}) };
    }
    const parts: Part[] = [];
    const guide = !taskId && this.sendGuide && this.guide.body;
    const taps = rows.filter((r) => r.kind === "event" && r.meta);
    // Tables handed to this agent: the server's one line opens the turn.
    const handed = [...new Set(rows.map((r) => r.meta?.tables).filter((t) => typeof t === "string" && t.trim()))];
    const words = [...handed, ...rows.map((r) => r.body)].join("\n");
    const rowsBack = inflight.tables;
    if (card && isLangGraph(card)) {
      parts.push({ text: words });
      const data: Record<string, unknown> = {};
      if (guide) data.yui_channel_guide = { version: this.guide.version, body: this.guide.body };
      if (taps.length) data.yui_events = taps.map((r) => ({ ...r.meta, row: r.id }));
      if (rowsBack) data.yui_tables = rowsBack;
      if (guide || taps.length || rowsBack) parts.push({ data, metadata: { yui: "context" } });
    } else {
      if (guide) parts.push({ text: this.guide.body, metadata: { yui: "channel_guide", version: this.guide.version } });
      parts.push({ text: words });
      for (const r of taps) parts.push({ data: r.meta, metadata: { yui: "event", row: r.id } }); // a tap, as data too
      if (rowsBack) parts.push({ data: rowsBack });
    }
    return { messageId: inflight.messageId, role: "user", parts, contextId: agentId, ...(taskId ? { taskId } : {}) };
  }

  /** One tables call. Never throws: a failure is logged and comes back as null with why. */
  async callTables(agent: YuiAgent, body: { lines: string } | { reply: string }): Promise<{ r: any; why?: string }> {
    try {
      const [s, r] = await this.tables({ agent: agent.id, ...body });
      if (s === 200 && r && typeof r === "object") return { r };
      const why = `${s} ${r?.error ?? ""}${r?.message ? `: ${r.message}` : ""}`.trim();
      log(`${agent.name}: tables call refused (${why})`);
      return { r: null, why };
    } catch (e) {
      log(`${agent.name}: tables call failed (${(e as Error).message})`);
      return { r: null, why: (e as Error).message };
    }
  }

  /**
   * The tables in an answer (spec TABLES.md section 8). Data parts {"yui": "tables", "lines"} run first: with
   * words for the person their rows ride on the next message, alone they are a read. Then table words in the
   * text go through the reply call, and its text is what the person gets. A read hands back the parts to send
   * the agent now (twice a turn at most); otherwise the text to save ("" saves nothing).
   */
  async tablesIn(agent: YuiAgent, view: TaskView, text: string, inflight: Inflight, card?: AgentCard):
    Promise<{ text: string; followup?: Part[] }> {
    const aid = agent.id;
    const more = (inflight.round ?? 0) < READ_ROUNDS;
    const calls = view.data().filter((d: any) => d?.yui === "tables" && typeof d.lines === "string" && d.lines.trim()) as any[];
    if (calls.length) {
      const back: Record<string, unknown> & { results: any[]; failed: any[] } = { yui: "tables", results: [], failed: [], held: null };
      const notes: string[] = [];
      for (const d of calls) {
        const { r, why } = await this.callTables(agent, { lines: d.lines });
        if (!r) {
          back.failed.push({ line: d.lines, error: `Yui could not run these lines just now (${why}). Nothing was written.` });
          continue;
        }
        back.results.push(...(r.results ?? []));
        back.failed.push(...(r.failed ?? []));
        if (r.held) back.held = r.held;
        if (r.tables !== undefined) back.tables = r.tables;
        if (r.note) notes.push(r.note);
      }
      const note = notes.join("\n\n") || tablesSummary(back);
      if (!text && more) return { text, followup: this.rowsBack(note, back, card) };
      this.state.data.tables[aid] = back; // saved with the reply (queueReply) or the end of the turn
    }
    if (text && TABLE_WORDS.test(text)) {
      const { r } = await this.callTables(agent, { reply: text });
      if (r?.read) {
        if (more && typeof r.note === "string" && r.note) return { text: "", followup: this.rowsBack(r.note, null, card) };
        return { text: "" }; // only reads, and no rounds left: nothing for the person
      }
      if (r && typeof r.text === "string") {
        if ((r.failed ?? []).length) log(`${agent.name}: ${r.failed.length} table line(s) refused`);
        return { text: r.text.trim() };
      }
    }
    return { text };
  }

  /** What goes back to the agent for a read: the rows in words, and as data when there is data. */
  rowsBack(note: string, data: Record<string, unknown> | null, card?: AgentCard): Part[] {
    const parts: Part[] = [{ text: note }];
    if (data) parts.push(card && isLangGraph(card) ? { data: { yui_tables: data }, metadata: { yui: "context" } } : { data });
    return parts;
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
      rows = await this.fresh(aid);
      if (!rows.length) {
        await this.flushAcks();
        return;
      }
      const turn = rows.map((r) => r.id);
      // Same rows, same id: an agent that dedupes by messageId sees a resend once.
      const messageId = "yui-" + createHash("sha256").update(`${aid}:${turn.join(",")}`).digest("hex").slice(0, 32);
      inflight = { turn, messageId, taskId: null, started: Date.now() };
      const back = this.state.data.tables[aid]; // rows the last answer asked for go out with this message
      if (back) inflight.tables = back;
      delete this.state.data.tables[aid];
      this.state.data.inflight[aid] = inflight;
      this.state.save();
      await this.mark(turn, "delivered_at"); // the app's working row starts here
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
    } else if (inflight.taskId) {
      log(`${agent.name}: picking task ${inflight.taskId.slice(0, 8)} back up`);
    } else if (inflight.followup) {
      log(`${agent.name}: sending its table rows again (no task id before the restart)`);
    } else {
      rows = await this.rowsById(aid, inflight.turn); // crashed before the agent named a task: send again
      await this.mark(inflight.turn, "delivered_at"); // in case the crash came before the first mark
      log(`${agent.name}: sending ${inflight.turn.length} message(s) again (no task id before the restart)`);
    }

    for (;;) {
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
      if (state && INTERRUPTED.has(state)) this.state.data.open[aid] = view.task!.id; // the next message continues this task
      else delete this.state.data.open[aid];
      const said = !(state === "failed" || state === "rejected" || state === "canceled");
      if (said) {
        const t = await this.tablesIn(agent, view, text, inflight, c.card);
        if (t.followup) { // a read: the rows go back as the next message, the person sees nothing yet
          inflight.round = (inflight.round ?? 0) + 1;
          inflight.followup = t.followup;
          inflight.taskId = null;
          this.state.save();
          log(`${agent.name}: sent its table rows back (read ${inflight.round} of ${READ_ROUNDS})`);
          continue;
        }
        text = t.text;
      }
      if (state === "auth-required") text = `${name} needs you to sign in before it can go on.${text ? `\n\n${text}` : ""}`;
      else if (state && INTERRUPTED.has(state) && !text) text = `${name} needs more from you to go on.`;
      else if (!said) {
        const what = state === "rejected" ? "turned that down" : state === "canceled" ? "stopped that task" : "couldn't finish that";
        text = `${name} ${what}.${text ? `\n\n${text}` : ""}`;
      }
      log(`${agent.name}: task ${state ?? "answered"}${view.task ? ` (${view.task.id.slice(0, 8)})` : ""}, ${text.length} chars`);
      if (text) {
        this.queueReply(aid, text, inflight.turn);
      } else { // nothing to say: the turn is done
        this.endTurn(aid, inflight.turn);
      }
      break;
    }
    await this.flushOutbox();
    await this.flushAcks();
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
    this.startHeartbeat();
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
}

/** A few words for a tables result the server sent no note for. */
function tablesSummary(t: { results: any[]; failed: any[] }): string {
  const bits = t.results.map((r) => `${r.table}: ${r.count ?? r.rows?.length ?? 0} row(s)`);
  for (const f of t.failed) bits.push(`Refused "${f.line}": ${f.error}`);
  return `[yui] Your tables: ${bits.join("; ") || "done"}. Answer the person now.`;
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
