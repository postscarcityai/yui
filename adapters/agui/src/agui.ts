// AG-UI client (INT-21): run an agent served by any AG-UI server and fold its
// event stream into one answer.
//
// AG-UI (docs.ag-ui.com) is run-per-turn: the client POSTs a RunAgentInput
// (the thread's messages, the tools the client offers, context, state) and
// reads Server-Sent Events back until RUN_FINISHED or RUN_ERROR. The server
// keeps nothing between runs unless it wants to, so the client owns the
// thread. A tool the client offers is declaration-only on the server: when
// the model calls it the run ends, the client does the work, and the result
// goes back as a tool message in the next run (AG-UI's human in the loop).
//
// Runtime-neutral: fetch and the SSE parser only, no Node APIs, so the hosted
// step can run it on Cloudflare like the A2A client.
import { readSse } from "../../a2a/src/sse.ts";

// -- wire types (camelCase, as every AG-UI server sends them) -----------------------------

export interface ToolCall { id: string; type: "function"; function: { name: string; arguments: string } }
export type Message =
  | { id: string; role: "system" | "developer"; content: string }
  | { id: string; role: "user"; content: string }
  | { id: string; role: "assistant"; content?: string; toolCalls?: ToolCall[] }
  | { id: string; role: "tool"; content: string; toolCallId: string };
export interface Tool { name: string; description: string; parameters?: unknown }
export interface Context { description: string; value: string }
export interface Interrupt { id: string; reason: string; message?: string; toolCallId?: string }
export interface ResumeEntry { interruptId: string; status: "resolved" | "cancelled"; payload?: unknown }
export interface RunAgentInput {
  threadId: string;
  runId: string;
  messages: Message[];
  tools: Tool[];
  context: Context[];
  state?: unknown;
  forwardedProps: unknown;
  resume?: ResumeEntry[];
}
export interface AgEvent { type: string; [k: string]: any }

/** The server said no to the request itself (4xx): sending it again won't help. */
export class AguiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
/** Unreachable, 5xx, or a stream that stopped before the run finished: try again. */
export class AguiUnavailable extends Error {}

export interface RunOptions {
  headers?: Record<string, string>;
  fetch?: typeof fetch;
  idle?: number; // seconds with no bytes before the stream counts as dropped (default 300)
  signal?: AbortSignal;
}

/** POSTs one run and yields its events in order. Throws AguiUnavailable if the stream ends early. */
export async function* runAgent(url: string, input: RunAgentInput, opts: RunOptions = {}): AsyncGenerator<AgEvent> {
  const ctl = new AbortController();
  const idle = (opts.idle ?? 300) * 1000;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const poke = () => {
    clearTimeout(timer);
    timer = setTimeout(() => ctl.abort(new Error(`no data for ${idle / 1000}s`)), idle);
  };
  opts.signal?.addEventListener("abort", () => ctl.abort(opts.signal!.reason), { once: true });
  let r: Response;
  poke();
  try {
    r = await (opts.fetch ?? fetch)(url, {
      method: "POST",
      body: JSON.stringify(input),
      headers: { "content-type": "application/json", accept: "text/event-stream", ...opts.headers },
      signal: ctl.signal,
    });
  } catch (e: any) {
    clearTimeout(timer);
    throw new AguiUnavailable(String(e?.cause?.code ?? e?.message ?? e));
  }
  try {
    if (!r.ok || !r.body) {
      const text = (await r.text().catch(() => "")).slice(0, 300);
      if (r.status >= 500 || [408, 425, 429].includes(r.status)) throw new AguiUnavailable(`${r.status} ${text}`);
      throw new AguiError(r.status, `${r.status} ${text}`.trim());
    }
    let ended = false;
    try {
      for await (const ev of readSse(r.body, poke)) {
        let e: AgEvent;
        try {
          e = JSON.parse(ev.data);
        } catch {
          continue; // not ours (a keep-alive with data, a proxy's note)
        }
        if (!e || typeof e.type !== "string") continue;
        yield e;
        if (e.type === "RUN_FINISHED" || e.type === "RUN_ERROR") {
          ended = true;
          return;
        }
      }
    } catch (e: any) {
      if (e instanceof AguiError) throw e;
      throw new AguiUnavailable(String(ctl.signal.reason?.message ?? e?.message ?? e));
    }
    if (!ended) throw new AguiUnavailable("the stream ended before the run finished");
  } finally {
    clearTimeout(timer);
  }
}

// -- folding a run ----------------------------------------------------------------------------

/** One run's events, folded: the assistant's words, its tool calls, and how it ended. */
export class RunView {
  messages: Message[] = []; // what the run added to the thread, in order
  finished = false;
  error: { message: string; code?: string } | null = null;
  interrupts: Interrupt[] = [];
  state: unknown = undefined; // the last STATE_SNAPSHOT, if any
  private byId = new Map<string, Message>();
  private calls = new Map<string, ToolCall>();
  private lastText: string | null = null; // TEXT_MESSAGE_CHUNK without an id continues the last one
  private lastCall: string | null = null;

  private assistant(id: string): Extract<Message, { role: "assistant" }> {
    let m = this.byId.get(id);
    if (!m) {
      m = { id, role: "assistant" };
      this.byId.set(id, m);
      this.messages.push(m);
    }
    return m as Extract<Message, { role: "assistant" }>;
  }

  private call(id: string, name: string | undefined, parent: string | undefined): ToolCall {
    let c = this.calls.get(id);
    if (!c) {
      c = { id, type: "function", function: { name: name ?? "", arguments: "" } };
      this.calls.set(id, c);
      // A call joins its parent message; with none named it gets one of its own.
      const m = this.assistant(parent ?? `call-${id}`);
      (m.toolCalls ??= []).push(c);
    } else if (name && !c.function.name) {
      c.function.name = name;
    }
    return c;
  }

  apply(e: AgEvent): void {
    switch (e.type) {
      case "TEXT_MESSAGE_START":
        if ((e.role ?? "assistant") === "assistant") this.assistant(e.messageId);
        this.lastText = e.messageId;
        break;
      case "TEXT_MESSAGE_CONTENT":
      case "TEXT_MESSAGE_CHUNK": {
        const id = e.messageId ?? this.lastText ?? "text";
        if (e.role && e.role !== "assistant") break;
        this.lastText = id;
        const m = this.assistant(id);
        m.content = (m.content ?? "") + (e.delta ?? "");
        break;
      }
      case "TOOL_CALL_START":
        this.call(e.toolCallId, e.toolCallName, e.parentMessageId);
        this.lastCall = e.toolCallId;
        break;
      case "TOOL_CALL_ARGS":
      case "TOOL_CALL_CHUNK": {
        const id = e.toolCallId ?? this.lastCall;
        if (!id) break;
        this.lastCall = id;
        this.call(id, e.toolCallName, e.parentMessageId).function.arguments += e.delta ?? "";
        break;
      }
      case "TOOL_CALL_RESULT": // a server-side tool ran: its result is part of the thread
        this.messages.push({ id: e.messageId ?? `result-${e.toolCallId}`, role: "tool", toolCallId: e.toolCallId,
                             content: String(e.content ?? "") });
        break;
      case "STATE_SNAPSHOT":
        this.state = e.snapshot;
        break;
      case "RUN_FINISHED":
        this.finished = true;
        if (e.outcome?.type === "interrupt") this.interrupts = e.outcome.interrupts ?? [];
        break;
      case "RUN_ERROR":
        this.finished = true;
        this.error = { message: String(e.message ?? "error"), ...(e.code ? { code: e.code } : {}) };
        break;
    }
  }

  /** Every word the assistant said, messages apart by a blank line. */
  text(): string {
    return this.messages.flatMap((m) => (m.role === "assistant" && m.content?.trim() ? [m.content.trim()] : [])).join("\n\n");
  }

  /** Calls the server left for the client: a tool call with no result in this run. */
  openCalls(): ToolCall[] {
    const done = new Set(this.messages.flatMap((m) => (m.role === "tool" ? [m.toolCallId] : [])));
    return [...this.calls.values()].filter((c) => !done.has(c.id));
  }

  /** The thread's new messages, ready to send back next run (empty assistant shells dropped). */
  thread(): Message[] {
    return this.messages.filter((m) => m.role !== "assistant" || m.content?.trim() || m.toolCalls?.length)
      .map((m) => (m.role === "assistant" && !m.content ? (({ content: _c, ...rest }) => rest)(m) as Message : m));
  }
}
