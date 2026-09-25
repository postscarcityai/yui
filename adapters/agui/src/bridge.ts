// The Yui side of the AG-UI bridge (INT-21, step 1: runs on your machine).
//
// The relay is the A2A bridge's (adapters/a2a/src/relay.ts, shared with Flue):
// rows in yui_messages are the contract (yuigui/spec/RELAY.md), every person's
// row is marked delivered when a turn starts and handled once its answer is
// written, replies name their rows in meta.turn, and anything that must
// survive a crash is on disk before it happens.
//
// What is AG-UI-specific:
//   - one Yui agent = one AG-UI endpoint URL; one Yui thread = one AG-UI
//     thread (threadId = the Yui agent id);
//   - AG-UI servers keep nothing between runs, so the bridge keeps the thread
//     (the messages, on disk) and sends it with every run;
//   - each turn is one run: runId comes from the turn's rows, so a turn sent
//     again after a crash is the same run;
//   - Yui screens are a frontend tool, yui_show(lines). The model calls it,
//     the run ends there, the lines go to the phone, and what the person taps
//     goes back as the tool's result in the next run;
//   - the channel guide rides as a system message (default), in yui_show's
//     description (--guide tool) or in AG-UI's context (--guide context).
//     Agent Framework drops context unless A2UI is on, hence the default.
//
// Node only (files, crypto). The protocol code in agui.ts is runtime-neutral.
import { createHash } from "node:crypto";
import {
  AguiError, AguiUnavailable, RunView, runAgent, type Context, type Interrupt, type Message, type ResumeEntry,
  type RunAgentInput, type Tool, type ToolCall,
} from "./agui.ts";
import {
  BACKOFF_MAX, Refused, Retry, State as RelayState, YuiRelay, addAgent, logger, pairConnector, refFromName as rf, sleep,
  type Inflight, type Row, type StateData as RelayData, type YuiAgent,
} from "../../a2a/src/relay.ts";

export { SUPABASE_URL, Refused, Retry, connectCall } from "../../a2a/src/relay.ts";
const UA = "yui-agui/1";
export const MAX_THREAD = 60; // messages kept for the next run
export const SHOW = "yui_show";

export const log = logger("yui-agui");
export const refFromName = (name: string) => rf(name, "agui");

// -- state ------------------------------------------------------------------------------

/** An AG-UI endpoint this machine serves, by the Yui agent's remote_ref. */
export interface Remote {
  url: string; // where RunAgentInput is POSTed
  headers?: Record<string, string>; // e.g. authorization
  name?: string;
}

export interface StateData extends RelayData {
  remotes: Record<string, Remote>;
  threads: Record<string, Message[]>; // Yui agent id -> the AG-UI thread so far
  calls: Record<string, ToolCall[]>; // Yui agent id -> client tool calls waiting on the person
  interrupts: Record<string, Interrupt[]>; // Yui agent id -> interrupts waiting on the person
  agstate: Record<string, unknown>; // Yui agent id -> the agent's last STATE_SNAPSHOT
}

export class State extends RelayState<StateData> {
  constructor(path: string) {
    super(path, { remotes: {}, threads: {}, calls: {}, interrupts: {}, agstate: {} });
  }
}

const RESET = { threads: {}, calls: {}, interrupts: {}, agstate: {} };

export async function pair(state: State, code: string, ref: string, remote: Remote, hostName?: string): Promise<any> {
  const r = await pairConnector(state, code, ref, { hostName, kind: "http", reset: RESET, ua: UA });
  state.data.remotes[ref] = remote;
  state.save();
  return r;
}

/** Another AG-UI agent on an already paired machine: a new Yui agent, no code. */
export async function add(state: State, ref: string, remote: Remote, name?: string): Promise<any> {
  if (!state.data.token) throw new Refused("not paired yet: run `pair <code> --url <endpoint>` first");
  const r = await addAgent(state, ref, name, UA);
  state.data.remotes[ref] = remote;
  state.save();
  return r;
}

// -- the yui_show tool ----------------------------------------------------------------------

export const SHOW_DESCRIPTION = "Show a screen on the person's phone in Yui. `lines` is Yui Lines, one element per line, "
  + "no code fence (for example `choose \"Lunch?\" Soup|Salad|Wrap`). Use it whenever the answer is something to tap, "
  + "pick, fill in, time or look at. Anything you also say in text shows above the screen. The run ends here: what the "
  + "person taps comes back as this tool's result, as a line like `[yui] n1 choose choice=Soup`.";

export function showTool(guide?: string): Tool {
  return {
    name: SHOW,
    description: guide ? `${SHOW_DESCRIPTION}\n\nHow to write Yui Lines (the Yui channel guide):\n\n${guide}` : SHOW_DESCRIPTION,
    parameters: {
      type: "object",
      properties: { lines: { type: "string", description: "Yui Lines, one element per line" } },
      required: ["lines"],
    },
  };
}

/** The Yui Lines in a yui_show call, fenced for the reply. Models vary: a string, a list, or bare text. */
export function showLines(call: ToolCall): string {
  let lines: unknown = call.function.arguments;
  try {
    const a = JSON.parse(call.function.arguments || "{}");
    lines = a && typeof a === "object" ? (a as any).lines ?? (a as any).yl ?? (a as any).screen ?? "" : a;
  } catch {}
  const text = (Array.isArray(lines) ? lines.join("\n") : String(lines ?? "")).trim();
  if (!text) return "";
  return text.includes("```yui") ? text : "```yui\n" + text.replace(/^```\w*\n?|\n?```$/g, "").trim() + "\n```";
}

// -- the bridge -------------------------------------------------------------------------------------

export type GuideMode = "system" | "tool" | "context" | "off";

export interface BridgeOptions {
  interval?: number; // seconds between reads
  guide?: GuideMode; // where the channel guide rides (default system)
  fetch?: typeof fetch; // for the AG-UI side only
  idle?: number; // seconds of silence before a run counts as dropped
}

export class Bridge extends YuiRelay<StateData> {
  declare state: State;
  interval: number;
  guideMode: GuideMode;
  aguiFetch?: typeof fetch;
  idle?: number;
  private jobs = new Map<string, Promise<void>>(); // one turn at a time per agent
  private retryAt = new Map<string, number>();
  private backoff = new Map<string, number>();
  private fatal?: Error;

  constructor(state: State, opts: BridgeOptions = {}) {
    super(state, { ua: UA, log });
    this.interval = opts.interval ?? 2;
    this.guideMode = opts.guide ?? "system";
    this.aguiFetch = opts.fetch;
    this.idle = opts.idle;
  }

  get ct(): string {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code> --url <endpoint>`");
    return this.state.data.token;
  }

  protected onAgent(a: YuiAgent): void {
    const remote = this.state.data.remotes[a.remote_ref];
    log(remote ? `serving ${a.name} (${a.id.slice(0, 8)}) -> ${remote.url}` : `${a.name} (${a.remote_ref}) has no AG-UI endpoint on this machine; skipping it`);
  }

  /** The turn's messages: results for the calls the person answered, then their words. */
  turnMessages(aid: string, rows: Row[], runId: string): { messages: Message[]; resume?: ResumeEntry[] } {
    const out: Message[] = [];
    const calls = this.state.data.calls[aid] ?? [];
    const taps = rows.filter((r) => r.kind === "event");
    const words = calls.length ? rows.filter((r) => r.kind !== "event") : rows; // with no screen open, a tap is just words
    const first = calls.findIndex((c) => c.function.name === SHOW); // the taps answer the first screen
    calls.forEach((c, i) => {
      let content: string;
      if (c.function.name !== SHOW) content = `Yui has no tool named ${c.function.name}; only ${SHOW}.`;
      else if (i === first && taps.length) content = taps.map((r) => r.body).join("\n");
      else content = words.length ? "Shown. They wrote back instead of tapping; their words follow." : "Shown.";
      out.push({ id: `${runId}-r${i}`, role: "tool", toolCallId: c.id, content });
    });
    if (calls.length && taps.length && first < 0) words.unshift(...taps);
    if (words.length) out.push({ id: `yui-${words[0].id}`, role: "user", content: words.map((r) => r.body).join("\n") });
    const open = this.state.data.interrupts[aid] ?? [];
    const resume = open.length
      ? open.map((it) => ({ interruptId: it.id, status: "resolved" as const, payload: { text: rows.map((r) => r.body).join("\n") } }))
      : undefined;
    return { messages: out, resume };
  }

  /** The RunAgentInput for a turn. */
  input(aid: string, rows: Row[], runId: string): { input: RunAgentInput; turn: Message[] } {
    const { messages: turn, resume } = this.turnMessages(aid, rows, runId);
    const guide = this.guideMode !== "off" && this.guide.body ? this.guide.body : "";
    const pre: Message[] = guide && this.guideMode === "system"
      ? [{ id: `yui-channel-guide-${this.guide.version || "0"}`, role: "system", content: guide }] : [];
    const context: Context[] = guide && this.guideMode === "context"
      ? [{ description: `Yui channel guide ${this.guide.version}: how to answer with screens`, value: guide }] : [];
    const input: RunAgentInput = {
      threadId: aid,
      runId,
      messages: [...pre, ...(this.state.data.threads[aid] ?? []), ...turn],
      tools: [showTool(this.guideMode === "tool" ? guide : undefined)],
      context,
      state: this.state.data.agstate[aid] ?? {},
      forwardedProps: {},
      ...(resume ? { resume } : {}),
    };
    return { input, turn };
  }

  /** What the phone gets for a finished run, and the thread from here on. */
  settle(aid: string, name: string, turn: Message[], view: RunView): string {
    const d = this.state.data;
    const thread = [...(d.threads[aid] ?? []), ...turn];
    let text: string;
    if (view.error) {
      text = `${name} couldn't finish that.\n\n${view.error.message}`;
      d.threads[aid] = trim(thread);
      delete d.calls[aid];
      delete d.interrupts[aid];
      return text;
    }
    thread.push(...view.thread());
    const open = view.openCalls();
    const screens = open.filter((c) => c.function.name === SHOW).map(showLines).filter(Boolean);
    for (const c of open) if (c.function.name !== SHOW) log(`${name} called ${c.function.name}, which Yui doesn't offer`);
    text = [view.text(), ...screens].filter(Boolean).join("\n\n");
    if (view.interrupts.length) {
      const asks = view.interrupts.map((i) => i.message || i.reason).filter(Boolean);
      text = [text, ...asks].filter(Boolean).join("\n\n") || `${name} needs more from you to go on.`;
      d.interrupts[aid] = view.interrupts;
    } else {
      delete d.interrupts[aid];
    }
    if (open.length) d.calls[aid] = open;
    else delete d.calls[aid];
    if (view.state !== undefined) d.agstate[aid] = view.state;
    d.threads[aid] = trim(thread);
    return text;
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

  /** One turn for one agent: the one in flight again, or a new one from new rows. */
  async turn(agent: YuiAgent): Promise<void> {
    const aid = agent.id;
    const remote = this.state.data.remotes[agent.remote_ref];
    if (!remote) return;
    let inflight: Inflight | undefined = this.state.data.inflight[aid];
    let rows: Row[];
    if (!inflight) {
      rows = await this.fresh(aid);
      if (!rows.length) {
        await this.flushAcks();
        return;
      }
      const turn = rows.map((r) => r.id);
      // Same rows, same run: a turn sent again after a crash carries the same runId.
      const messageId = "yui-" + createHash("sha256").update(`${aid}:${turn.join(",")}`).digest("hex").slice(0, 32);
      inflight = { turn, messageId, started: Date.now() };
      this.state.data.inflight[aid] = inflight;
      this.state.save();
      await this.mark(turn, "delivered_at"); // the app's working row starts here
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
    } else {
      // AG-UI can't rejoin a run, and the thread only moves on when a run settles: run it again.
      rows = await this.rowsById(aid, inflight.turn);
      await this.mark(inflight.turn, "delivered_at");
      log(`${agent.name}: running ${inflight.turn.length} message(s) again after a restart`);
    }

    const { input, turn } = this.input(aid, rows, inflight.messageId);
    const view = new RunView();
    try {
      for await (const e of runAgent(remote.url, input, { headers: remote.headers, fetch: this.aguiFetch, idle: this.idle })) {
        view.apply(e);
      }
    } catch (e) {
      if (e instanceof AguiError) {
        view.apply({ type: "RUN_ERROR", message: `It answered with an error: ${e.message}` });
      } else if (e instanceof AguiUnavailable) {
        if (!this.running) return; // stopping: the turn is on disk, the next run sends it again
        throw e; // back off and run it again (same runId)
      } else {
        throw e;
      }
    }
    const name = remote.name || agent.name;
    const text = this.settle(aid, name, turn, view);
    log(`${agent.name}: run ${view.error ? "failed" : "finished"}${this.state.data.calls[aid] ? ", a screen is waiting" : ""}, ${text.length} chars`);
    if (text) {
      this.queueReply(aid, text, inflight.turn); // the thread above and the reply land in one save
    } else {
      this.endTurn(aid, inflight.turn);
    }
    await this.flushOutbox();
    await this.flushAcks();
  }

  async run(): Promise<void> {
    await this.session();
    log(`online as ${this.state.data.connector?.name}; guide ${this.guide?.version} (${this.guideMode})`);
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

/** The last MAX_THREAD messages, cut at a person's message so no tool result loses its call. */
export function trim(thread: Message[]): Message[] {
  if (thread.length <= MAX_THREAD) return thread;
  const tail = thread.slice(-MAX_THREAD);
  const i = tail.findIndex((m) => m.role === "user");
  return i < 0 ? tail : tail.slice(i);
}
