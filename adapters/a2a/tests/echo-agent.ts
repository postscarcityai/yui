// A scripted A2A agent for tests. No model: every answer is fixed by the text
// it gets, so tests can say exactly what should land in the thread.
//
//   node tests/echo-agent.ts [--port 0] [--protocol 1.0|0.3] [--no-streaming]
//
// Prints `listening <base url>` once ready. Speaks the JSON-RPC binding of the
// version it was started with, serves its Agent Card at
// /.well-known/agent-card.json, and keeps every call in GET /_log.
//
// What it does with a message (its text parts, the Yui context part skipped):
//   "slow N"   (any text with "slow" and a number) a task that works for N
//              seconds: a working status, an artifact in N append chunks one
//              second apart, then completed
//   "ask ..."  input-required ("Which color?"); the next message on that task
//              completes it ("<answer> it is.")
//   "fail"     failed, with a status message
//   "ping"     a plain Message, no task
//   "...screen..." completed with a ```yui screen
//   a tap      "[yui] <id> choose choice=X" -> "X it is."
//   anything   completed, one artifact: "You said: <text>"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";

const { values: o } = parseArgs({
  options: {
    port: { type: "string", default: "0" },
    protocol: { type: "string", default: "1.0" },
    "no-streaming": { type: "boolean", default: false },
    name: { type: "string", default: "Echo" },
  },
});
const V = o.protocol === "0.3" ? "0.3" : "1.0";
const STREAMING = !o["no-streaming"];

type State = "submitted" | "working" | "input-required" | "completed" | "failed";
interface Part { text?: string; data?: unknown; metadata?: Record<string, unknown> }
interface Msg { messageId: string; role: "user" | "agent"; parts: Part[]; taskId?: string; contextId?: string }
interface Artifact { artifactId: string; parts: Part[] }
interface Task {
  id: string; contextId: string; state: State; message?: Msg; artifacts: Artifact[];
  subs: Set<(ev: any) => void>; plan?: string;
}

const tasks = new Map<string, Task>();
const log: any[] = [];

// -- wire shapes for the version in use ----------------------------------------------------

const wState = (s: State) => (V === "1.0" ? `TASK_STATE_${s.toUpperCase().replace(/-/g, "_")}` : s);
const wPart = (p: Part) => (V === "1.0" ? p : p.text !== undefined ? { kind: "text", ...p } : { kind: "data", ...p });
const wMsg = (m: Msg) => ({
  ...(V === "0.3" ? { kind: "message" } : {}),
  messageId: m.messageId, role: V === "1.0" ? (m.role === "user" ? "ROLE_USER" : "ROLE_AGENT") : m.role,
  parts: m.parts.map(wPart), ...(m.taskId ? { taskId: m.taskId } : {}), ...(m.contextId ? { contextId: m.contextId } : {}),
});
const wArtifact = (a: Artifact) => ({ artifactId: a.artifactId, parts: a.parts.map(wPart) });
const wStatus = (t: Task) => ({ state: wState(t.state), ...(t.message ? { message: wMsg(t.message) } : {}), timestamp: new Date().toISOString() });
const wTask = (t: Task) => ({
  ...(V === "0.3" ? { kind: "task" } : {}), id: t.id, contextId: t.contextId, status: wStatus(t), artifacts: t.artifacts.map(wArtifact),
});
const final = (s: State) => ["completed", "failed", "input-required"].includes(s);
const evTask = (t: Task) => (V === "1.0" ? { task: wTask(t) } : wTask(t));
const evStatus = (t: Task) => {
  const su = { taskId: t.id, contextId: t.contextId, status: wStatus(t) };
  return V === "1.0" ? { statusUpdate: su } : { kind: "status-update", ...su, final: final(t.state) };
};
const evArtifact = (t: Task, a: Artifact, append: boolean, lastChunk: boolean) => {
  const au = { taskId: t.id, contextId: t.contextId, artifact: wArtifact(a), append, lastChunk };
  return V === "1.0" ? { artifactUpdate: au } : { kind: "artifact-update", ...au };
};
const evMessage = (m: Msg) => (V === "1.0" ? { message: wMsg(m) } : wMsg(m));

function readParts(raw: any[]): Part[] {
  return (raw ?? []).map((p) => {
    const text = typeof p.text === "string" ? p.text : undefined;
    return { ...(text !== undefined ? { text } : { data: p.data }), ...(p.metadata ? { metadata: p.metadata } : {}) };
  });
}
const personText = (parts: Part[]) =>
  parts.filter((p) => p.text !== undefined && !(p.metadata as any)?.yui).map((p) => p.text).join("\n");
const agentMsg = (text: string, t?: Task): Msg =>
  ({ messageId: randomUUID(), role: "agent", parts: [{ text }], ...(t ? { taskId: t.id, contextId: t.contextId } : {}) });

// -- the script ---------------------------------------------------------------------------

function emit(t: Task, ev: any) {
  for (const s of t.subs) s(ev);
}
function setState(t: Task, state: State, message?: Msg) {
  t.state = state;
  t.message = message;
  emit(t, evStatus(t));
  if (final(state)) for (const s of [...t.subs]) s(null); // end of stream
}

/** Runs a message against a task (new or continued); the task may keep going after we return. */
function handle(msg: Msg): Task | Msg {
  const text = personText(msg.parts).trim();
  if (!msg.taskId && text === "ping") return agentMsg("pong");
  let t = msg.taskId ? tasks.get(msg.taskId) : undefined;
  if (msg.taskId && !t) throw rpcError(-32001, "Task not found");
  if (t && final(t.state) && t.state !== "input-required") throw rpcError(-32004, "Task is over");
  if (!t) {
    t = { id: randomUUID(), contextId: msg.contextId ?? randomUUID(), state: "submitted", artifacts: [], subs: new Set() };
    tasks.set(t.id, t);
  }
  const task = t;
  if (task.plan === "ask") { // the answer to "Which color?"
    task.plan = undefined;
    task.state = "working";
    queueMicrotask(() => {
      task.artifacts.push({ artifactId: "answer", parts: [{ text: `${text} it is.` }] });
      emit(task, evArtifact(task, task.artifacts[0], false, true));
      setState(task, "completed");
    });
    return task;
  }
  const slow = /\bslow\b\D*(\d+)/i.exec(text);
  task.state = "working";
  if (slow) {
    const n = Number(slow[1]);
    const a: Artifact = { artifactId: "report", parts: [] };
    let i = 0;
    const tick = () => {
      if (!tasks.has(task.id)) return;
      i++;
      const chunk = { text: i === 1 ? `Step ${i}` : `, step ${i}` };
      const first = a.parts.length === 0;
      if (first) a.parts.push({ ...chunk });
      else a.parts[0].text += chunk.text;
      if (first) task.artifacts.push(a);
      emit(task, evArtifact(task, { artifactId: "report", parts: [chunk] }, !first, i === n));
      if (i < n) setTimeout(tick, 1000);
      else setState(task, "completed", agentMsg(`Done after ${n} steps.`, task));
    };
    setTimeout(() => {
      setState(task, "working", agentMsg("Working on it", task));
      setTimeout(tick, 1000);
    }, 200);
    return task;
  }
  queueMicrotask(() => {
    const tap = /^\[yui\] \S+ choose choice=(.+)$/.exec(text);
    if (/^ask\b/i.test(text)) {
      task.plan = "ask";
      setState(task, "input-required", agentMsg("Which color?", task));
    } else if (text === "fail") {
      setState(task, "failed", agentMsg("The printer is on fire.", task));
    } else {
      const reply = tap ? `${tap[1]} it is.`
        : /\bscreen\b/i.test(text) ? 'Pick one\n```yui\nchoose "Pick one" Tea|Coffee\n```' : `You said: ${text}`;
      task.artifacts.push({ artifactId: `a${task.artifacts.length}`, parts: [{ text: reply }] });
      emit(task, evArtifact(task, task.artifacts[task.artifacts.length - 1], false, true));
      setState(task, "completed");
    }
  });
  return task;
}

class RpcError extends Error { code: number; constructor(code: number, m: string) { super(m); this.code = code; } }
const rpcError = (code: number, m: string) => new RpcError(code, m);

const M = V === "1.0"
  ? { send: "SendMessage", stream: "SendStreamingMessage", sub: "SubscribeToTask", get: "GetTask", cancel: "CancelTask" }
  : { send: "message/send", stream: "message/stream", sub: "tasks/resubscribe", get: "tasks/get", cancel: "tasks/cancel" };

function card(base: string) {
  const common = {
    name: o.name, description: "A scripted test agent. It has no model.", version: "1.0.0",
    capabilities: { streaming: STREAMING, pushNotifications: false },
    defaultInputModes: ["text/plain"], defaultOutputModes: ["text/plain"],
    skills: [{ id: "echo", name: "Echo", description: "Says back what you say", tags: ["test"], examples: ["hello"] },
             { id: "slow", name: "Slow job", description: "Works for a while, streaming progress", tags: ["test"] }],
  };
  return V === "1.0"
    ? { ...common, supportedInterfaces: [{ url: `${base}/a2a`, protocolBinding: "JSONRPC", protocolVersion: "1.0" }] }
    : { ...common, url: `${base}/a2a`, preferredTransport: "JSONRPC", protocolVersion: "0.3.0" };
}

function json(res: ServerResponse, status: number, body: unknown) {
  const raw = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(raw) });
  res.end(raw);
}

function sse(res: ServerResponse, id: unknown, t: Task, first: any) {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  res.write(": hello\n\n");
  const send = (ev: any) => {
    if (ev === null) {
      t.subs.delete(send);
      res.end();
      return;
    }
    res.write(`data: ${JSON.stringify({ jsonrpc: "2.0", id, result: ev })}\n\n`);
  };
  send(first);
  if (final(t.state)) return res.end();
  t.subs.add(send);
  res.on("close", () => t.subs.delete(send));
}

async function body(req: IncomingMessage): Promise<string> {
  let s = "";
  for await (const c of req) s += c;
  return s;
}

const server = createServer(async (req, res) => {
  const base = `http://${req.headers.host}`;
  if (req.method === "GET" && req.url === "/.well-known/agent-card.json") return json(res, 200, card(base));
  if (req.method === "GET" && req.url === "/_log") return json(res, 200, log);
  if (req.method !== "POST" || req.url !== "/a2a") return json(res, 404, { error: "not found" });
  let env: any;
  try {
    env = JSON.parse(await body(req));
  } catch {
    return json(res, 200, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  const { id, method, params } = env;
  const version = req.headers["a2a-version"] ?? "";
  try {
    if (V === "1.0" && version !== "1.0") throw rpcError(-32009, `Version not supported: '${version}'`);
    if (method === M.send || method === M.stream) {
      if (method === M.stream && !STREAMING) throw rpcError(-32004, "Streaming is not supported");
      const m = params.message;
      const msg: Msg = { messageId: m.messageId, role: "user", parts: readParts(m.parts), taskId: m.taskId, contextId: m.contextId };
      log.push({ method, messageId: msg.messageId, taskId: msg.taskId ?? null, contextId: msg.contextId ?? null,
                 text: personText(msg.parts), context: msg.parts.filter((p) => (p.metadata as any)?.yui).map((p) => p.metadata),
                 version });
      const r = handle(msg);
      if (!("id" in r) || !(r as Task).subs) { // a plain message
        const ev = evMessage(r as Msg);
        if (method === M.stream) {
          res.writeHead(200, { "content-type": "text/event-stream" });
          res.end(`data: ${JSON.stringify({ jsonrpc: "2.0", id, result: ev })}\n\n`);
          return;
        }
        return json(res, 200, { jsonrpc: "2.0", id, result: V === "1.0" ? ev : wMsg(r as Msg) });
      }
      const t = r as Task;
      if (method === M.stream) return sse(res, id, t, evTask(t));
      const cfg = params.configuration ?? {};
      const wait = V === "1.0" ? !cfg.returnImmediately : cfg.blocking !== false;
      if (wait && !final(t.state)) {
        await new Promise<void>((resolve) => {
          const s = (ev: any) => { if (ev === null) { t.subs.delete(s); resolve(); } };
          t.subs.add(s);
          setImmediate(() => { if (final(t.state)) resolve(); });
        });
      }
      return json(res, 200, { jsonrpc: "2.0", id, result: evTask(t) });
    }
    if (method === M.sub) {
      log.push({ method, taskId: params.id });
      if (!STREAMING) throw rpcError(-32004, "Streaming is not supported");
      const t = tasks.get(params.id);
      if (!t) throw rpcError(-32001, "Task not found");
      if (final(t.state) && t.state !== "input-required") throw rpcError(-32004, "Task is over");
      return sse(res, id, t, evTask(t));
    }
    if (method === M.get) {
      log.push({ method, taskId: params.id });
      const t = tasks.get(params.id);
      if (!t) throw rpcError(-32001, "Task not found");
      return json(res, 200, { jsonrpc: "2.0", id, result: wTask(t) });
    }
    throw rpcError(-32601, `Method not found: ${method}`);
  } catch (e) {
    if (e instanceof RpcError) return json(res, 200, { jsonrpc: "2.0", id, error: { code: e.code, message: e.message } });
    throw e;
  }
});

server.listen(Number(o.port), "127.0.0.1", () => {
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : 0;
  console.log(`listening http://127.0.0.1:${port} (A2A ${V}${STREAMING ? "" : ", no streaming"})`);
});
