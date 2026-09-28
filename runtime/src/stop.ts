// Stop (YUI-190). Chris on TestFlight: "I actually do want to be able to cancel.
// While it's working in the back, I might be doing the wrong thing." The mic turns
// into a stop square while an agent works; a tap sends one control row
// (kind control, meta { op: "stop" }). Here:
//   - stopTurns answers it at once (never a turn): the agent's rows not answered
//     yet are handled, and its jobs not finished are dropped;
//   - guard wraps a running turn or job: every write asks first and throws Stopped
//     once a stop landed, and a watcher aborts the model call mid-answer. A stopped
//     turn writes nothing: no reply, no table rows, no memory, no job.
import type { Store } from "./store.ts";
import type { NativeAgent, Row } from "./types.ts";

export class Stopped extends Error {
  constructor() {
    super("stopped by the person");
    this.name = "Stopped";
  }
}

/** The person's Stop: a control row with op stop. */
export function isStop(row: Pick<Row, "kind" | "sender" | "meta"> | null | undefined): boolean {
  return !!row && row.kind === "control" && row.sender === "user" && row.meta?.op === "stop";
}

/** What the agent was doing for this person when the stop was sent: their waiting rows handled, their jobs
 *  dropped. Someone the agent is shared with (YUI-95) stops only their own. */
export async function stopTurns(store: Store, agent: NativeAgent, stop: Row & { user_id: string }): Promise<{ rows: number; jobs: number }> {
  const mine = (r: Row) => ((r as Row & { user_id?: string }).user_id ?? agent.userId) === stop.user_id;
  const rows = (await store.pending(agent.id)).filter((r) => r.created_at <= stop.created_at && mine(r)).map((r) => r.id);
  if (rows.length) await store.markHandled(rows);
  const jobs = await store.stopJobs(agent.id, stop.user_id, stop.created_at);
  await store.controlAnswer(agent, stop.id, "controls: stop", { ok: true, op: "stop", rows: rows.length, jobs });
  return { rows: rows.length, jobs };
}

/** Store calls that change something the person keeps: each asks about a stop first. */
const WRITES = new Set<string>(["reply", "saveTables", "saveMemory", "addJob", "addSchedule", "updateSchedule", "dropSchedule",
                                "setScheduleNext", "createAgent", "updateAgent", "removeAgent"]);

export interface Guard {
  store: Store; // writes throw Stopped once a stop landed
  signal: AbortSignal; // aborted when the stop is seen: the model call ends there
  fetch: typeof fetch; // the model side's fetch, with that signal
  /** Throws Stopped when a stop landed since the work began. */
  check(): Promise<void>;
  end(): void;
}

/**
 * Watches for this person's stop on this agent sent at or after `since` (the first row of the turn,
 * or the job's queue time). `poll` ms between looks while the model answers.
 */
export function guard(store: Store, agentId: string, userId: string, since: string, opts: { fetch?: typeof fetch; poll?: number } = {}): Guard {
  const ctl = new AbortController();
  const check = async () => {
    if (!ctl.signal.aborted && await store.stoppedSince(agentId, userId, since)) ctl.abort(new Stopped());
    if (ctl.signal.aborted) throw new Stopped();
  };
  let timer: ReturnType<typeof setInterval> | undefined = setInterval(() => {
    store.stoppedSince(agentId, userId, since).then((s) => { if (s && !ctl.signal.aborted) ctl.abort(new Stopped()); }, () => {});
  }, opts.poll ?? 1500);
  const base = opts.fetch ?? fetch;
  const guarded = new Proxy(store, {
    get(target, prop, receiver) {
      const v = Reflect.get(target, prop, receiver);
      if (typeof v !== "function") return v;
      if (typeof prop === "string" && WRITES.has(prop)) {
        return async (...args: unknown[]) => {
          await check();
          return v.apply(target, args);
        };
      }
      return v.bind(target);
    },
  });
  return {
    store: guarded,
    signal: ctl.signal,
    fetch: ((url: any, init?: RequestInit) =>
      base(url, { ...init, signal: init?.signal ? AbortSignal.any([init.signal, ctl.signal]) : ctl.signal })) as typeof fetch,
    check,
    end() {
      if (timer !== undefined) clearInterval(timer);
      timer = undefined;
    },
  };
}
