// Yui channel for Flue (INT-13): a Flue agent answers in Yui with screens, not paragraphs.
//
// Two ways in, one turn shape:
//   - createYuiConnector: the Flue app dials out to Yui (Node target). It reads
//     the person's rows, hands each turn to the project's answer(), and writes
//     the reply back exactly once. The relay rules are the A2A bridge's, from
//     the shared adapters/a2a/src/relay.ts: rows delivered when a turn starts,
//     handled once the answer is written, replies naming their rows in
//     meta.turn, an outbox on disk.
//   - createYuiChannel (channel.ts, Web-only, also for Cloudflare): verified
//     HTTP ingress, the Flue channel convention.
//     A turn arrives as a signed POST (the webhook bridge's format, and later
//     Yui's hosted connector) and the answer goes back in the response.
//
// Neither imports @flue/runtime. The project's channels/yui.ts owns dispatch:
// its answer() sends the turn to a Flue agent with init().dispatch() and
// returns the settled reply's text. The turn's `key` is stable across
// restarts; pass it as the dispatch idempotencyKey so a replayed turn
// converges on the first submission instead of running twice.
//
// The channel guide (spec/CHANNEL.md) comes with every Yui session and every
// pushed turn. yuiGuide() returns the newest one; put it in the agent's
// instructions (withYuiGuide) and the model answers with Yui screens.
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { setYuiGuide, type Answer, type YuiGuide, type YuiTurn } from "./channel.ts";
import {
  BACKOFF_MAX, Refused, Retry, State, YuiRelay, addAgent, logger, pairConnector, refFromName, sleep,
  type Inflight, type Row, type StateData, type YuiAgent,
} from "../../a2a/src/relay.ts";

export * from "./channel.ts";
export { Refused, Retry, State, refFromName };
export const UA = "yui-flue/1";
export const log = logger("yui-flue");
export const DEFAULT_STATE = process.env.YUI_FLUE_STATE ?? join(homedir(), ".yui/flue.json");

/** Same rows, same key: a resend is recognizable. Matches the webhook bridge's x-yui-turn. */
export function turnKey(turn: string[]): string {
  return createHash("sha256").update(turn.join(",")).digest("hex").slice(0, 32);
}

export function toTurn(agent: YuiAgent, rows: Row[], guide: YuiGuide): YuiTurn {
  const turn = rows.map((r) => r.id);
  return {
    agent: { id: agent.id, name: agent.name, handle: agent.handle, ref: agent.remote_ref },
    turn,
    key: turnKey(turn),
    text: rows.map((r) => r.body).join("\n"),
    messages: rows.map((r) => ({
      id: r.id, kind: r.kind, body: r.body, event: r.kind === "event" ? (r.meta ?? null) : null, created_at: r.created_at,
    })),
    guide,
  };
}

// -- dial out: the connector ------------------------------------------------------------------

export interface ConnectorOptions {
  answer: Answer;
  state?: string; // default ~/.yui/flue.json or $YUI_FLUE_STATE
  interval?: number; // seconds between reads (default 2)
  /** Only serve these remote_refs (default: every agent paired to this connector). */
  refs?: string[];
}

interface FlueData extends StateData {
  inflight: Record<string, Inflight & { key: string }>;
}

export class YuiConnector extends YuiRelay<FlueData> {
  answer: Answer;
  interval: number;
  refs?: Set<string>;
  private jobs = new Map<string, Promise<void>>(); // one turn at a time per agent
  private retryAt = new Map<string, number>();
  private backoff = new Map<string, number>();
  private fatal?: Error;
  private loop?: Promise<void>;

  constructor(opts: ConnectorOptions) {
    super(new State<FlueData>((opts.state ?? DEFAULT_STATE).replace(/^~(?=\/)/, homedir())), { ua: UA, log });
    this.answer = opts.answer;
    this.interval = opts.interval ?? 2;
    this.refs = opts.refs ? new Set(opts.refs) : undefined;
  }

  get paired(): boolean {
    return !!this.state.data.token;
  }

  serves(a: YuiAgent): boolean {
    return !this.refs || this.refs.has(a.remote_ref);
  }

  protected onAgent(a: YuiAgent): void {
    log(this.serves(a) ? `serving ${a.name} (${a.remote_ref}, ${a.id.slice(0, 8)})` : `${a.name} (${a.remote_ref}) is not served here; skipping it`);
  }

  async session(): Promise<void> {
    await super.session();
    setYuiGuide(this.guide);
  }

  /** Starts the loop in the background (the Flue server keeps running). Resolves once Yui answered. */
  async start(): Promise<void> {
    await this.session();
    log(`online as ${this.state.data.connector?.name}; guide ${this.guide.version}`);
    this.startHeartbeat();
    this.loop = this.run().catch((e) => log(`stopped: ${e?.message ?? e}`));
  }

  private async run(): Promise<void> {
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

  tick(): void {
    for (const [aid, agent] of this.agents) {
      if (!this.serves(agent) || this.jobs.has(aid) || (this.retryAt.get(aid) ?? 0) > Date.now() / 1000) continue;
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

  /** One turn for one agent: the one in flight after a restart, or new rows. */
  async turn(agent: YuiAgent): Promise<void> {
    const aid = agent.id;
    let inflight = this.state.data.inflight[aid];
    let rows: Row[];
    if (inflight) { // a restart, or a failed try: same rows, same key
      rows = await this.rowsById(aid, inflight.turn);
      await this.mark(inflight.turn, "delivered_at");
      log(`${agent.name}: sending ${inflight.turn.length} message(s) again (key ${inflight.key.slice(0, 8)})`);
    } else {
      rows = await this.fresh(aid);
      if (!rows.length) {
        await this.flushAcks();
        return;
      }
      const turn = rows.map((r) => r.id);
      inflight = { turn, key: turnKey(turn), messageId: `yui-${turnKey(turn)}`, started: Date.now() };
      this.state.data.inflight[aid] = inflight;
      this.state.save();
      await this.mark(turn, "delivered_at"); // the app's working row starts here
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
    }
    const text = ((await this.answer(toTurn(agent, rows, this.guide))) ?? "").trim();
    log(`${agent.name}: answered, ${text.length} chars`);
    if (text) this.queueReply(aid, text, inflight.turn);
    else this.endTurn(aid, inflight.turn);
    await this.flushOutbox();
    await this.flushAcks();
  }

  /** A clean stop on SIGINT and SIGTERM: Yui hears goodbye first, so the app shows the agent
   * offline at once instead of asleep. Flue's Node server exits as soon as it has drained, so
   * its process.exit waits for the goodbye (at most 5 s), then goes ahead with its own code. */
  stopOnSignals(): void {
    for (const sig of ["SIGINT", "SIGTERM"] as const) {
      process.once(sig, () => {
        const exit = process.exit;
        let asked = false;
        let code: number | string | undefined;
        process.exit = ((c?: number | string) => {
          if (!asked) code = c;
          asked = true;
        }) as typeof process.exit;
        void Promise.race([this.stop(), sleep(5)]).finally(() => {
          process.exit = exit;
          if (asked || process.listenerCount(sig) === 0) exit(code ?? 0);
        });
      });
    }
  }

  async stop(): Promise<void> {
    await super.stop();
    await Promise.race([Promise.allSettled(this.jobs.values()), sleep(5)]);
    await this.loop;
  }
}

/** The dial-out side. Nothing happens until start(). */
export function createYuiConnector(opts: ConnectorOptions): YuiConnector {
  return new YuiConnector(opts);
}

export async function pair(code: string, opts: { ref: string; state?: string; hostName?: string }): Promise<any> {
  const state = new State((opts.state ?? DEFAULT_STATE).replace(/^~(?=\/)/, homedir()));
  return pairConnector(state, code, opts.ref, { hostName: opts.hostName, kind: "http", ua: UA });
}

export async function add(ref: string, opts: { name?: string; state?: string } = {}): Promise<any> {
  const state = new State((opts.state ?? DEFAULT_STATE).replace(/^~(?=\/)/, homedir()));
  return addAgent(state, ref, opts.name, UA);
}

