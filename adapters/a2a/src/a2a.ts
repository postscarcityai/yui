// A2A client (INT-18), runtime-neutral: only `fetch`, `TextDecoder` and
// ReadableStream, so the same module runs in Node 22+, a Cloudflare Worker or
// Durable Object, and a browser. No Node APIs here; the Yui bridge lives in
// bridge.ts.
//
// Speaks the JSON-RPC binding of A2A 1.0 (SendMessage, SendStreamingMessage,
// SubscribeToTask, GetTask, CancelTask) and of 0.3 (message/send,
// message/stream, tasks/resubscribe, tasks/get, tasks/cancel), since agents in
// the wild run both. Callers see one version-free shape (the types below);
// the wire differences stay in this file.
//
// Spec: https://a2a-protocol.org/latest/specification/ (a2a.proto is normative).

import { readSse } from "./sse.ts";

export type Version = "1.0" | "0.3";

export type TaskState =
  | "submitted" | "working" | "input-required" | "auth-required"
  | "completed" | "failed" | "canceled" | "rejected" | "unknown";

/** No more updates will come for a task in these states. */
export const TERMINAL: ReadonlySet<TaskState> = new Set(["completed", "failed", "canceled", "rejected"]);
/** The task waits on the person (or on credentials); the next message continues it. */
export const INTERRUPTED: ReadonlySet<TaskState> = new Set(["input-required", "auth-required"]);

/** One piece of content. Exactly one of text, data, url, raw is set. */
export interface Part {
  text?: string;
  data?: unknown;
  url?: string;
  raw?: string; // base64
  mediaType?: string;
  filename?: string;
  metadata?: Record<string, unknown>;
}

export interface Message {
  messageId: string;
  role: "user" | "agent";
  parts: Part[];
  contextId?: string;
  taskId?: string;
  metadata?: Record<string, unknown>;
}

export interface Artifact {
  artifactId: string;
  name?: string;
  parts: Part[];
}

export interface Task {
  id: string;
  contextId?: string;
  state: TaskState;
  statusMessage?: Message;
  artifacts: Artifact[];
}

/** What a stream (or a send) yields, whichever version the agent speaks. */
export type Update =
  | { kind: "task"; task: Task }
  | { kind: "message"; message: Message }
  | { kind: "status"; taskId: string; contextId?: string; state: TaskState; message?: Message; final: boolean }
  | { kind: "artifact"; taskId: string; contextId?: string; artifact: Artifact; append: boolean; lastChunk: boolean };

export interface Skill {
  id: string;
  name: string;
  description?: string;
  examples?: string[];
}

export interface Interface {
  url: string;
  binding: string; // JSONRPC, HTTP+JSON, GRPC or a custom URI
  version: string; // as the card states it ("1.0", "0.3.0")
}

export interface AgentCard {
  name: string;
  description: string;
  version?: string;
  streaming: boolean;
  pushNotifications: boolean;
  skills: Skill[];
  interfaces: Interface[];
  raw: unknown;
}

/** The agent said no (JSON-RPC error, 4xx): retrying the same call won't help. */
export class A2AError extends Error {
  code: number;
  data: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.name = "A2AError";
    this.code = code;
    this.data = data;
  }
}

/** Network trouble, a 5xx or 429, a dropped stream: try again later. */
export class A2AUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "A2AUnavailable";
  }
}

// JSON-RPC error codes (spec section 5.4). TaskNotFound and UnsupportedOperation
// matter to callers: a task the agent forgot, or one that is already over.
export const TASK_NOT_FOUND = -32001;
export const TASK_NOT_CANCELABLE = -32002;
export const UNSUPPORTED_OPERATION = -32004;
export const VERSION_NOT_SUPPORTED = -32009;

type Fetch = typeof fetch;

export interface ClientOptions {
  /** Extra headers on every call, e.g. `authorization`. */
  headers?: Record<string, string>;
  fetch?: Fetch;
  /** Seconds to wait for a unary call. Default 120. */
  timeout?: number;
  /** Seconds a stream may stay silent before it counts as dropped. Default 300. */
  idleTimeout?: number;
}

const METHODS: Record<Version, Record<string, string>> = {
  "1.0": { send: "SendMessage", stream: "SendStreamingMessage", subscribe: "SubscribeToTask", get: "GetTask", cancel: "CancelTask" },
  "0.3": { send: "message/send", stream: "message/stream", subscribe: "tasks/resubscribe", get: "tasks/get", cancel: "tasks/cancel" },
};

// -- Agent Card ----------------------------------------------------------------------

/** Where the card lives for a URL the person pasted: the card itself, or a base URL. */
export function cardUrls(input: string): string[] {
  const u = new URL(input);
  if (u.pathname.endsWith(".json")) return [u.href];
  const base = u.origin + u.pathname.replace(/\/+$/, "");
  const origin = u.origin;
  const urls = [`${base}/.well-known/agent-card.json`];
  if (base !== origin) urls.push(`${origin}/.well-known/agent-card.json`);
  urls.push(`${origin}/.well-known/agent.json`); // name used before 0.3
  return [...new Set(urls)];
}

export async function fetchAgentCard(input: string, opts: ClientOptions = {}): Promise<{ url: string; card: AgentCard }> {
  const f = opts.fetch ?? fetch;
  let last = "";
  for (const url of cardUrls(input)) {
    let r: Response;
    try {
      r = await f(url, { headers: { accept: "application/json", ...(opts.headers ?? {}) },
                         signal: AbortSignal.timeout((opts.timeout ?? 30) * 1000) });
    } catch (e) {
      throw new A2AUnavailable(`agent card ${url}: ${errText(e)}`);
    }
    if (r.status === 404) {
      last = `${url}: 404`;
      continue;
    }
    if (r.status >= 500 || r.status === 429) throw new A2AUnavailable(`agent card ${url}: ${r.status}`);
    if (!r.ok) throw new A2AError(r.status, `agent card ${url}: ${r.status}`);
    let raw: unknown;
    try {
      raw = await r.json();
    } catch {
      throw new A2AError(0, `agent card ${url}: not JSON`);
    }
    return { url, card: parseAgentCard(raw, url) };
  }
  throw new A2AError(404, `no agent card found (${last})`);
}

/** A 1.0 or 0.3 card in one shape. Relative interface URLs resolve against `base`. */
export function parseAgentCard(raw: any, base?: string): AgentCard {
  if (!raw || typeof raw !== "object" || typeof raw.name !== "string") throw new A2AError(0, "agent card has no name");
  const abs = (u: string) => (base ? new URL(u, base).href : u);
  const interfaces: Interface[] = [];
  for (const i of raw.supportedInterfaces ?? []) { // 1.0
    if (i?.url) interfaces.push({ url: abs(i.url), binding: String(i.protocolBinding ?? "JSONRPC"), version: String(i.protocolVersion ?? "1.0") });
  }
  if (raw.url) { // 0.3: url + preferredTransport, more in additionalInterfaces
    const v = String(raw.protocolVersion ?? "0.3");
    interfaces.push({ url: abs(raw.url), binding: String(raw.preferredTransport ?? "JSONRPC"), version: v });
    for (const i of raw.additionalInterfaces ?? []) {
      if (i?.url) interfaces.push({ url: abs(i.url), binding: String(i.transport ?? "JSONRPC"), version: v });
    }
  }
  return {
    name: raw.name,
    description: String(raw.description ?? ""),
    version: raw.version,
    streaming: !!raw.capabilities?.streaming,
    pushNotifications: !!raw.capabilities?.pushNotifications,
    skills: (raw.skills ?? []).filter((s: any) => s?.name).map((s: any) => ({
      id: String(s.id ?? s.name), name: s.name, description: s.description, examples: s.examples,
    })),
    interfaces,
    raw,
  };
}

/** A LangGraph Agent Server (its card lists LangChain's A2A extensions). It turns each text
 * part into its own message under one id, so a second text part replaces the first, and it
 * drops part metadata; data parts become keys of the graph's input instead. */
export function isLangGraph(card: AgentCard): boolean {
  const ext = (card.raw as any)?.capabilities?.extensions;
  return Array.isArray(ext) && ext.some((e: any) => String(e?.uri ?? "").startsWith("https://langchain.com/a2a/"));
}

/** The JSON-RPC interface to use: 1.x before 0.3, the first listed on a tie. */
export function pickInterface(card: AgentCard): { url: string; version: Version } | null {
  const rpc = card.interfaces.filter((i) => i.binding.toUpperCase().replace(/[-_]/g, "") === "JSONRPC");
  const major = (v: string) => Number.parseInt(v, 10);
  const v1 = rpc.find((i) => major(i.version) === 1);
  if (v1) return { url: v1.url, version: "1.0" };
  const v0 = rpc.find((i) => /^0\.3(\.|$)/.test(i.version) || major(i.version) === 0);
  return v0 ? { url: v0.url, version: "0.3" } : null;
}

// -- wire <-> plain shapes ---------------------------------------------------------------

export function normState(s: unknown): TaskState {
  const v = String(s ?? "").toLowerCase().replace(/^task_state_/, "").replace(/_/g, "-");
  const known: TaskState[] = ["submitted", "working", "input-required", "auth-required", "completed", "failed", "canceled", "rejected"];
  if (v === "cancelled") return "canceled";
  return (known as string[]).includes(v) ? (v as TaskState) : "unknown";
}

function partFromWire(p: any): Part | null {
  if (!p || typeof p !== "object") return null;
  const meta = p.metadata && typeof p.metadata === "object" ? { metadata: p.metadata } : {};
  if (typeof p.text === "string") return { text: p.text, ...meta };
  if (p.kind === "file" || p.file) { // 0.3
    const f = p.file ?? {};
    const out: Part = { mediaType: f.mimeType, filename: f.name, ...meta };
    if (f.uri) out.url = f.uri;
    else if (f.bytes) out.raw = f.bytes;
    return out;
  }
  if ("data" in p) return { data: p.data, ...meta };
  if (typeof p.url === "string") return { url: p.url, mediaType: p.mediaType, filename: p.filename, ...meta };
  if (typeof p.raw === "string") return { raw: p.raw, mediaType: p.mediaType, filename: p.filename, ...meta };
  return null;
}

function partToWire(p: Part, v: Version): any {
  const meta = p.metadata ? { metadata: p.metadata } : {};
  if (v === "1.0") {
    if (p.text !== undefined) return { text: p.text, ...meta };
    if (p.data !== undefined) return { data: p.data, ...meta };
    const out: any = { ...meta };
    if (p.url !== undefined) out.url = p.url;
    else out.raw = p.raw;
    if (p.mediaType) out.mediaType = p.mediaType;
    if (p.filename) out.filename = p.filename;
    return out;
  }
  if (p.text !== undefined) return { kind: "text", text: p.text, ...meta };
  if (p.data !== undefined) return { kind: "data", data: p.data, ...meta };
  const file: any = p.url !== undefined ? { uri: p.url } : { bytes: p.raw };
  if (p.mediaType) file.mimeType = p.mediaType;
  if (p.filename) file.name = p.filename;
  return { kind: "file", file, ...meta };
}

function messageFromWire(m: any): Message | undefined {
  if (!m || typeof m !== "object") return undefined;
  const role = String(m.role ?? "").toLowerCase().includes("user") ? "user" : "agent";
  const out: Message = {
    messageId: String(m.messageId ?? ""),
    role,
    parts: (m.parts ?? []).map(partFromWire).filter(Boolean) as Part[],
  };
  if (m.contextId) out.contextId = m.contextId;
  if (m.taskId) out.taskId = m.taskId;
  if (m.metadata) out.metadata = m.metadata;
  return out;
}

export function messageToWire(m: Message, v: Version): any {
  const out: any = {
    messageId: m.messageId,
    role: v === "1.0" ? (m.role === "user" ? "ROLE_USER" : "ROLE_AGENT") : m.role,
    parts: m.parts.map((p) => partToWire(p, v)),
  };
  if (v === "0.3") out.kind = "message";
  if (m.contextId) out.contextId = m.contextId;
  if (m.taskId) out.taskId = m.taskId;
  if (m.metadata) out.metadata = m.metadata;
  return out;
}

function artifactFromWire(a: any): Artifact {
  return {
    artifactId: String(a?.artifactId ?? ""),
    ...(a?.name ? { name: a.name } : {}),
    parts: (a?.parts ?? []).map(partFromWire).filter(Boolean) as Part[],
  };
}

export function taskFromWire(t: any): Task {
  if (!t || typeof t !== "object" || !t.id) throw new A2AError(0, "agent sent a task with no id");
  return {
    id: String(t.id),
    ...(t.contextId ? { contextId: t.contextId } : {}),
    state: normState(t.status?.state),
    ...(t.status?.message ? { statusMessage: messageFromWire(t.status.message) } : {}),
    artifacts: (t.artifacts ?? []).map(artifactFromWire),
  };
}

/** One result of a send or one stream event, from either version's shape. */
export function updateFromWire(r: any): Update {
  if (!r || typeof r !== "object") throw new A2AError(0, "agent sent an empty result");
  // 1.0: a one-key wrapper. 0.3: the object itself with a `kind`.
  if (r.task) return { kind: "task", task: taskFromWire(r.task) };
  if (r.message && !r.status && !r.kind) return { kind: "message", message: messageFromWire(r.message)! };
  const su = r.statusUpdate ?? (r.kind === "status-update" ? r : null);
  if (su) {
    const state = normState(su.status?.state);
    return {
      kind: "status", taskId: String(su.taskId), contextId: su.contextId, state,
      ...(su.status?.message ? { message: messageFromWire(su.status.message) } : {}),
      // 1.0 dropped `final`: the state says it.
      final: su.final === true || TERMINAL.has(state) || INTERRUPTED.has(state),
    };
  }
  const au = r.artifactUpdate ?? (r.kind === "artifact-update" ? r : null);
  if (au) {
    return { kind: "artifact", taskId: String(au.taskId), contextId: au.contextId, artifact: artifactFromWire(au.artifact),
             append: !!au.append, lastChunk: !!au.lastChunk };
  }
  if (r.kind === "task" || (r.id && r.status)) return { kind: "task", task: taskFromWire(r) };
  if (r.kind === "message" || (r.messageId && r.parts)) return { kind: "message", message: messageFromWire(r)! };
  throw new A2AError(0, `agent sent a result Yui can't read: ${JSON.stringify(r).slice(0, 200)}`);
}

// -- the client --------------------------------------------------------------------------------

export class A2AClient {
  readonly url: string;
  readonly version: Version;
  private f: Fetch;
  private headers: Record<string, string>;
  private timeout: number;
  private idleTimeout: number;
  private seq = 0;

  constructor(url: string, version: Version, opts: ClientOptions = {}) {
    this.url = url;
    this.version = version;
    this.f = opts.fetch ?? ((...a: Parameters<Fetch>) => fetch(...a));
    this.headers = opts.headers ?? {};
    this.timeout = opts.timeout ?? 120;
    this.idleTimeout = opts.idleTimeout ?? 300;
  }

  /** Read the card and pick its JSON-RPC interface. */
  static async fromCard(input: string, opts: ClientOptions = {}): Promise<{ client: A2AClient; card: AgentCard; cardUrl: string }> {
    const { url, card } = await fetchAgentCard(input, opts);
    const i = pickInterface(card);
    if (!i) {
      const have = card.interfaces.map((x) => `${x.binding} ${x.version}`).join(", ") || "none";
      throw new A2AError(0, `${card.name} has no JSON-RPC interface Yui can use (it lists: ${have})`);
    }
    return { client: new A2AClient(i.url, i.version, opts), card, cardUrl: url };
  }

  private method(op: string): string {
    return METHODS[this.version][op];
  }

  private reqHeaders(accept: string): Record<string, string> {
    const h: Record<string, string> = { "content-type": "application/json", accept, ...this.headers };
    if (this.version === "1.0") h["A2A-Version"] = "1.0"; // an empty header means 0.3
    return h;
  }

  private body(method: string, params: unknown): string {
    return JSON.stringify({ jsonrpc: "2.0", id: `yui-${++this.seq}`, method, params });
  }

  private async post(method: string, params: unknown, accept: string, signal: AbortSignal): Promise<Response> {
    let r: Response;
    try {
      r = await this.f(this.url, { method: "POST", headers: this.reqHeaders(accept), body: this.body(method, params), signal });
    } catch (e) {
      throw new A2AUnavailable(`${method}: ${errText(e)}`);
    }
    if (r.status >= 500 || r.status === 429 || r.status === 408) {
      await r.body?.cancel().catch(() => {});
      throw new A2AUnavailable(`${method}: HTTP ${r.status}`);
    }
    if (!r.ok && !(r.headers.get("content-type") ?? "").includes("json")) {
      await r.body?.cancel().catch(() => {});
      throw new A2AError(r.status, `${method}: HTTP ${r.status}`);
    }
    return r;
  }

  private async unary(method: string, params: unknown): Promise<any> {
    const r = await this.post(method, params, "application/json", AbortSignal.timeout(this.timeout * 1000));
    let env: any;
    try {
      env = await r.json();
    } catch (e) {
      throw new A2AUnavailable(`${method}: ${errText(e)}`);
    }
    return unwrap(method, env);
  }

  private async *streamCall(method: string, params: unknown): AsyncGenerator<Update> {
    const ctl = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const idle = () => {
      clearTimeout(timer);
      timer = setTimeout(() => ctl.abort(new Error(`no data for ${this.idleTimeout}s`)), this.idleTimeout * 1000);
    };
    idle();
    try {
      const r = await this.post(method, params, "text/event-stream", ctl.signal);
      const type = r.headers.get("content-type") ?? "";
      if (!type.includes("text/event-stream")) { // an error, or a server that answered in one go
        let env: any;
        try {
          env = await r.json();
        } catch (e) {
          throw new A2AUnavailable(`${method}: ${errText(e)}`);
        }
        yield updateFromWire(unwrap(method, env));
        return;
      }
      try {
        for await (const ev of readSse(r.body!, idle)) {
          if (!ev.data.trim()) continue;
          let env: any;
          try {
            env = JSON.parse(ev.data);
          } catch {
            throw new A2AError(0, `${method}: bad JSON in the stream`);
          }
          yield updateFromWire(unwrap(method, env));
        }
      } catch (e) {
        if (e instanceof A2AError || e instanceof A2AUnavailable) throw e;
        throw new A2AUnavailable(`${method}: stream dropped (${errText(ctl.signal.reason ?? e)})`);
      }
    } finally {
      clearTimeout(timer);
    }
  }

  /** Send and wait: the agent answers with a Task (maybe still working) or a Message. */
  async send(message: Message, opts: { returnImmediately?: boolean; acceptedOutputModes?: string[] } = {}): Promise<Update> {
    const params = this.sendParams(message, opts);
    return updateFromWire(await this.unary(this.method("send"), params));
  }

  /** Send and follow the task as it runs. Ends when the task is terminal or waits on the person. */
  stream(message: Message, opts: { acceptedOutputModes?: string[] } = {}): AsyncGenerator<Update> {
    return this.streamCall(this.method("stream"), this.sendParams(message, opts));
  }

  /** Pick a running task back up after a dropped stream or a restart. */
  subscribe(taskId: string): AsyncGenerator<Update> {
    return this.streamCall(this.method("subscribe"), { id: taskId });
  }

  async getTask(taskId: string, historyLength?: number): Promise<Task> {
    const params: any = { id: taskId };
    if (historyLength !== undefined) params.historyLength = historyLength;
    const r = await this.unary(this.method("get"), params);
    return taskFromWire(r?.task ?? r); // some 1.0 servers wrap it
  }

  async cancel(taskId: string): Promise<Task> {
    const r = await this.unary(this.method("cancel"), { id: taskId });
    return taskFromWire(r?.task ?? r);
  }

  private sendParams(message: Message, opts: { returnImmediately?: boolean; acceptedOutputModes?: string[] }): any {
    const modes = opts.acceptedOutputModes ?? ["text/plain", "text/markdown", "application/json"];
    const configuration: any = { acceptedOutputModes: modes };
    if (this.version === "1.0") {
      if (opts.returnImmediately) configuration.returnImmediately = true;
    } else {
      configuration.blocking = !opts.returnImmediately;
    }
    return { message: messageToWire(message, this.version), configuration };
  }
}

function unwrap(method: string, env: any): any {
  if (env?.error) {
    const e = env.error;
    throw new A2AError(Number(e.code ?? 0), `${method}: ${e.message ?? "error"} (${e.code})`, e.data);
  }
  if (!env || !("result" in env)) throw new A2AError(0, `${method}: not a JSON-RPC response`);
  return env.result;
}

function errText(e: unknown): string {
  const any = e as any;
  return String(any?.cause?.code ?? any?.message ?? e);
}

// -- turning a task into what the person reads -------------------------------------------------

/** The text parts, in order; file links as their URL. Data parts are skipped. */
export function partsText(parts: Part[]): string {
  return parts.map((p) => (p.text !== undefined ? p.text : p.url ?? "")).filter((s) => s.trim()).join("\n");
}

/** Applies artifact updates the way the spec says: `append` adds parts to the artifact with that id. */
export class TaskView {
  task: Task | null = null;
  message: Message | null = null; // a reply that came as a plain Message, no task
  private artifacts = new Map<string, Artifact>();

  apply(u: Update): void {
    if (u.kind === "message") {
      this.message = u.message;
      return;
    }
    if (u.kind === "task") {
      this.task = { ...u.task, artifacts: [] };
      this.artifacts.clear();
      // Copies all the way down: appends edit parts in place, and the same update may feed two views.
      for (const a of u.task.artifacts) this.artifacts.set(a.artifactId, { ...a, parts: a.parts.map((p) => ({ ...p })) });
      return;
    }
    if (!this.task) this.task = { id: u.taskId, contextId: u.contextId, state: "submitted", artifacts: [] };
    if (u.kind === "status") {
      // The message belongs to this status: a "Looking..." from working must not outlive it.
      this.task.state = u.state;
      if (u.message) this.task.statusMessage = u.message;
      else delete this.task.statusMessage;
      return;
    }
    const had = this.artifacts.get(u.artifact.artifactId);
    if (had && u.append) {
      // Text chunks glue onto the last text part; anything else is a new part.
      for (const p of u.artifact.parts) {
        const last = had.parts[had.parts.length - 1];
        if (p.text !== undefined && last?.text !== undefined) last.text += p.text;
        else had.parts.push({ ...p });
      }
    } else {
      this.artifacts.set(u.artifact.artifactId, { ...u.artifact, parts: u.artifact.parts.map((p) => ({ ...p })) });
    }
  }

  get state(): TaskState | null {
    return this.message ? "completed" : this.task?.state ?? null;
  }

  get artifactList(): Artifact[] {
    return [...this.artifacts.values()];
  }

  /** Done for this turn: terminal, waiting on the person, or a plain message. */
  get settled(): boolean {
    const s = this.state;
    return !!s && (TERMINAL.has(s) || INTERRUPTED.has(s));
  }

  /** What the person should read: the artifacts, then the status message if it says something new. */
  text(): string {
    if (this.message) return partsText(this.message.parts);
    const bits = this.artifactList.map((a) => partsText(a.parts)).filter((s) => s.trim());
    const status = this.task?.statusMessage ? partsText(this.task.statusMessage.parts) : "";
    if (status.trim() && !bits.some((b) => b.trim() === status.trim())) bits.push(status);
    return bits.join("\n\n");
  }
}
