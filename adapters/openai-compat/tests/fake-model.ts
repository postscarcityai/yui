#!/usr/bin/env node
// A scripted OpenAI-compatible server for the tests: no model, fixed answers
// picked by the last line the person sent. Streams like Ollama and vLLM do
// (SSE, "data: [DONE]"), or not at all.
//
//   node tests/fake-model.ts [--port 0] [--no-streaming] [--refuse-stream] [--key K] [--no-done]
//
// Prints "fake-model <base url>" first. GET /_log lists every request.
//
//   hello            -> "You said: hello"
//   screen           -> a ```yui choose screen, Tea|Coffee
//   [yui] n1 choose choice=X -> "X it is."
//   slow N           -> N pieces a second apart, then "Done after N steps."
//   history          -> the earlier messages it was sent, one per line
//   flaky            -> 503 the first time, then "Back again."
//   drop             -> the first stream breaks halfway, then "Whole this time."
//   down N           -> 503 for N seconds after the first try, then "Up again."
//   refuse           -> 400, the context is too long
//   think            -> a <think> block, then "Thought it through."
//   anything else    -> "You said: <it>"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { parseArgs } from "node:util";

export interface FakeOptions {
  port?: number;
  streaming?: boolean; // false: answers JSON even when asked to stream
  refuseStream?: boolean; // 400 on stream: true, like a server that can't
  key?: string; // wants Authorization: Bearer <key>
  done?: boolean; // false: ends streams on finish_reason, no [DONE]
}

export interface Fake {
  url: string;
  log: any[];
  close(): Promise<void>;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function startFake(opts: FakeOptions = {}): Promise<Fake> {
  const log: any[] = [];
  const seen = new Map<string, number>(); // text -> first time / count
  const server = createServer(async (req, res) => {
    try {
      await handle(req, res);
    } catch (e) {
      if (!res.headersSent) res.writeHead(500).end(String(e));
    }
  });

  async function handle(req: IncomingMessage, res: ServerResponse) {
    const url = new URL(req.url ?? "/", "http://x");
    if (req.method === "GET" && url.pathname === "/_log") return json(res, 200, log);
    if (opts.key && req.headers.authorization !== `Bearer ${opts.key}`) {
      return json(res, 401, { error: { message: "Incorrect API key provided", type: "invalid_request_error" } });
    }
    if (req.method === "GET" && url.pathname === "/v1/models") {
      return json(res, 200, { object: "list", data: [{ id: "fake-1", object: "model" }, { id: "fake-2", object: "model" }] });
    }
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") return json(res, 404, { error: { message: "no such route" } });
    let raw = "";
    for await (const c of req) raw += c;
    const body = JSON.parse(raw);
    const msgs: { role: string; content: string }[] = body.messages ?? [];
    const last = msgs[msgs.length - 1]?.content ?? "";
    const line = last.split("\n").pop()!.trim();
    log.push({ model: body.model, stream: !!body.stream, messages: msgs, text: last, auth: req.headers.authorization ?? null,
               max_tokens: body.max_tokens, temperature: body.temperature, at: Date.now() });
    if (body.model !== "fake-1" && body.model !== "fake-2") {
      return json(res, 404, { error: { message: `model "${body.model}" not found, try pulling it first` } });
    }
    if (body.stream && opts.refuseStream) return json(res, 400, { error: { message: "stream is not supported by this server" } });
    const n = (seen.get(line) ?? 0) + 1;
    seen.set(line, n);

    let pieces: string[];
    let wait = 0;
    let m: RegExpMatchArray | null;
    if (line === "hello") pieces = ["You said: ", "hello"];
    else if (line === "screen") pieces = ["Pick one:\n", "```yui\nchoose \"Pick one\" Tea|Coffee\n```"];
    else if ((m = line.match(/^\[yui\] n1 choose choice=(\w+)/))) pieces = [`${m[1]} it is.`];
    else if ((m = line.match(/^slow (\d+)$/))) {
      const k = Number(m[1]);
      pieces = [...Array.from({ length: k }, (_, i) => `${i ? ", s" : "S"}tep ${i + 1}`), `\n\nDone after ${k} steps.`];
      wait = 1000;
    } else if (line === "history") {
      pieces = [msgs.slice(1, -1).map((x) => `${x.role}: ${x.content.split("\n")[0]}`).join("\n") || "(nothing before)"];
    } else if (line === "flaky") {
      if (n === 1) return json(res, 503, { error: { message: "model is loading" } });
      pieces = ["Back again."];
    } else if ((m = line.match(/^down (\d+)$/))) {
      const key = `down-start:${line}`;
      if (!seen.has(key)) seen.set(key, Date.now());
      if (Date.now() - seen.get(key)! < Number(m[1]) * 1000) return json(res, 503, { error: { message: "server is starting" } });
      pieces = ["Up again."];
    } else if (line === "refuse") {
      return json(res, 400, { error: { message: "This model's maximum context length is 4096 tokens", type: "invalid_request_error" } });
    } else if (line === "think") pieces = ["<think>Let me see.", " Tea or coffee.</think>", "Thought it through."];
    else if (line === "drop") pieces = n === 1 ? ["Half of ", "the answer", "DROP"] : ["Whole this time."];
    else pieces = [`You said: ${line}`];

    const id = `chatcmpl-${log.length}`;
    if (!body.stream || opts.streaming === false) {
      for (const _ of pieces) if (wait) await sleep(wait);
      const text = pieces.filter((p) => p !== "DROP").join("");
      return json(res, 200, { id, object: "chat.completion", model: body.model,
        choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" }],
        usage: { prompt_tokens: raw.length >> 2, completion_tokens: text.length >> 2 } });
    }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const send = (d: unknown) => res.write(`data: ${JSON.stringify(d)}\n\n`);
    send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] });
    for (const p of pieces) {
      if (p === "DROP") {
        await sleep(150); // let the first pieces reach the client
        res.socket?.destroy(); // mid-stream, no finish
        return;
      }
      if (wait) await sleep(wait);
      send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: p }, finish_reason: null }] });
    }
    send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] });
    if (opts.done !== false) res.write("data: [DONE]\n\n");
    res.end();
  }

  return new Promise((resolve) => {
    server.listen(opts.port ?? 0, "127.0.0.1", () => {
      const port = (server.address() as any).port;
      resolve({ url: `http://127.0.0.1:${port}/v1`, log,
                close: () => new Promise<void>((r) => { server.closeAllConnections(); server.close(() => r()); }) });
    });
  });
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values: o } = parseArgs({ options: {
    port: { type: "string", default: "0" }, "no-streaming": { type: "boolean" }, "refuse-stream": { type: "boolean" },
    key: { type: "string" }, "no-done": { type: "boolean" },
  } });
  const f = await startFake({ port: Number(o.port), streaming: !o["no-streaming"], refuseStream: o["refuse-stream"],
                              key: o.key, done: !o["no-done"] });
  console.log(`fake-model ${f.url}`);
}
