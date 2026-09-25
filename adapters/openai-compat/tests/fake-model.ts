#!/usr/bin/env node
// A scripted OpenAI-compatible server for the tests: no model, fixed answers
// picked by the last line the person sent. Streams like Ollama and vLLM do
// (SSE, "data: [DONE]"), or not at all.
//
//   node tests/fake-model.ts [--port 0] [--no-streaming] [--refuse-stream] [--key K] [--no-done] [--gemini] [--grok] [--meta]
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
//
// --gemini answers the way Google's OpenAI-compatible endpoint does (INT-9):
// model ids listed as "models/<id>", every error wrapped in a list with a
// status word, a bad key as 400 INVALID_ARGUMENT, no role-only first chunk,
// the last piece carrying finish_reason and usage. Two more lines:
//   thought          -> a thought summary (extra_content.google.thought when
//                       streamed, a <thought> block when plain), then "Tea, then."
//   blocked          -> no text, finish_reason content_filter
//   quota            -> 429 RESOURCE_EXHAUSTED the first time, then "Quota back."
//
// --grok answers the way xAI's API does (INT-10): every error as
// {"code": "<words>", "error": "<message>"}, a bad key as 400 "Incorrect API
// key provided", and a 400 for stop, presence_penalty or frequency_penalty
// (reasoning models refuse them). More lines:
//   reason           -> reasoning_content first (deltas, or on the message), then "Tea, then."
//   busy             -> 429 rate limit the first time, then "Back in line."
//   broke            -> 403, the team is out of credits
//   decline          -> no content, a refusal saying why
//
// --meta answers the way Meta's Model API does for Muse Spark (INT-11):
// errors as {"error": {"message", "type", "param", "code"}}, a bad key as 401
// invalid_api_key, a 404 with no body for a path it doesn't have, a 400 for
// stop, n > 1, logit_bias and the other arguments it refuses, and
// reasoning_content always there but redacted to "". More lines:
//   reason           -> an empty reasoning_content first (as Muse Spark sends), then "Tea, then."
//   busy             -> 429 rate_limit_exceeded with Retry-After: 2 the first time, then "Back in line."
//   broke            -> 402 billing_error, insufficient balance
//   locked           -> 403, the key has no access to this model
//   unsafe           -> 400, content policy violation
//   long             -> 400, input_tokens + max_output_tokens must fit the window
//   timeout          -> plain: 504 gateway_timeout; streamed: "Streamed in time."
//   overload         -> streamed: a piece, then an "error" event (service_overloaded) the first time; then "Calm again."
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { parseArgs } from "node:util";

export interface FakeOptions {
  port?: number;
  streaming?: boolean; // false: answers JSON even when asked to stream
  refuseStream?: boolean; // 400 on stream: true, like a server that can't
  key?: string; // wants Authorization: Bearer <key>
  done?: boolean; // false: ends streams on finish_reason, no [DONE]
  gemini?: boolean; // Gemini's shapes, see above
  grok?: boolean; // xAI's shapes, see above
  meta?: boolean; // Meta Model API's shapes, see above
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
    const fail = (status: number, message: string, word: string | null) => opts.gemini
      ? json(res, status, [{ error: { code: status, message, status: word } }])
      : opts.grok ? json(res, status, { code: XAI_CODES[word ?? ""] ?? word, error: message })
      : opts.meta ? json(res, status, { error: { message, type: META_TYPES[status] ?? "invalid_request_error", param: null, code: word } })
      : json(res, status, { error: { message, type: "invalid_request_error" } });
    if (opts.key && req.headers.authorization !== `Bearer ${opts.key}`) {
      if (opts.gemini) return fail(400, "API key not valid. Please pass a valid API key.", "INVALID_ARGUMENT");
      if (opts.grok) return fail(400, "Incorrect API key provided: wr***ng. You can obtain an API key from https://console.x.ai.", "INVALID_ARGUMENT");
      if (opts.meta) return fail(401, "Invalid API key provided.", "invalid_api_key");
      return fail(401, "Incorrect API key provided", "UNAUTHENTICATED");
    }
    if (req.method === "GET" && url.pathname === "/v1/models") {
      const id = (x: string) => (opts.gemini ? `models/${x}` : x);
      const owner = opts.gemini ? "google" : opts.grok ? "xai" : opts.meta ? "meta" : "fake";
      return json(res, 200, { object: "list", data: [{ id: id("fake-1"), object: "model", owned_by: owner },
                                                     { id: id("fake-2"), object: "model", owned_by: owner }] });
    }
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return opts.meta ? void res.writeHead(404).end() : fail(404, "no such route", "NOT_FOUND");
    }
    let raw = "";
    for await (const c of req) raw += c;
    const body = JSON.parse(raw);
    const msgs: { role: string; content: string }[] = body.messages ?? [];
    const last = msgs[msgs.length - 1]?.content ?? "";
    const line = last.split("\n").pop()!.trim();
    log.push({ model: body.model, stream: !!body.stream, messages: msgs, text: last, auth: req.headers.authorization ?? null,
               max_tokens: body.max_tokens, temperature: body.temperature, keys: Object.keys(body), at: Date.now() });
    if (body.model !== "fake-1" && body.model !== "fake-2") {
      if (opts.meta) return fail(404, `The model \`${body.model}\` does not exist or you do not have access to it.`, "model_not_found");
      return fail(404, `model "${body.model}" not found, try pulling it first`, "NOT_FOUND");
    }
    const refused = ["stop", "presence_penalty", "frequency_penalty"].find((k) => opts.grok && k in body);
    if (refused) return fail(400, `Argument not supported on this model: ${refused}`, "INVALID_ARGUMENT");
    const metaRefused = opts.meta && (["stop", "logit_bias", "prediction", "web_search_options", "modalities", "audio", "verbosity"].find((k) => k in body)
      ?? ((body.n ?? 1) > 1 ? "n" : body.reasoning_effort === "none" ? "reasoning_effort" : undefined));
    if (metaRefused) return fail(400, `'${metaRefused}' is not supported with this model.`, null);
    if (body.stream && opts.refuseStream) return json(res, 400, { error: { message: "stream is not supported by this server" } });
    const n = (seen.get(line) ?? 0) + 1;
    seen.set(line, n);

    let pieces: string[];
    let wait = 0;
    let thought = "";
    let reasoning = "";
    let refusal = "";
    let fin = "stop";
    let failMidStream = false;
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
    else if (opts.gemini && line === "thought") {
      thought = "Tea suits the afternoon.";
      pieces = ["Tea, ", "then."];
    } else if (opts.gemini && line === "blocked") {
      pieces = [];
      fin = "content_filter";
    } else if (opts.gemini && line === "quota") {
      if (n === 1) return fail(429, "Resource has been exhausted (e.g. check quota).", "RESOURCE_EXHAUSTED");
      pieces = ["Quota back."];
    }
    else if (opts.grok && line === "reason") {
      reasoning = "Tea suits the afternoon.";
      pieces = ["Tea, ", "then."];
    } else if (opts.grok && line === "busy") {
      if (n === 1) return fail(429, "Rate limit reached for requests. Try again in a moment.", "RESOURCE_EXHAUSTED");
      pieces = ["Back in line."];
    } else if (opts.grok && line === "broke") {
      return fail(403, "Your team has either used all available credits or reached its monthly spending limit. "
        + "To continue making API requests, please purchase more credits or raise your spending limit.", "PERMISSION_DENIED");
    } else if (opts.grok && line === "decline") {
      pieces = [];
      refusal = "I can't help with that one.";
    }
    else if (opts.meta && line === "reason") pieces = ["Tea, ", "then."]; // reasoning_content comes, empty
    else if (opts.meta && line === "busy") {
      if (n === 1) {
        res.setHeader("retry-after", "2");
        return fail(429, "Rate limit exceeded: too many requests per minute. Please retry after a short wait.", "rate_limit_exceeded");
      }
      pieces = ["Back in line."];
    } else if (opts.meta && line === "broke") {
      return fail(402, "Insufficient balance. Add funds to your account to continue.", "insufficient_balance");
    } else if (opts.meta && line === "locked") {
      return fail(403, "Your API key does not have access to this model.", "permission_denied");
    } else if (opts.meta && line === "unsafe") {
      return fail(400, "The request was rejected because it violates the content policy.", "content_policy_violation");
    } else if (opts.meta && line === "long") {
      return fail(400, "Request too long: input_tokens + max_output_tokens must fit within the model's context window.", "context_length_exceeded");
    } else if (opts.meta && line === "timeout") {
      if (!body.stream) return fail(504, "The request timed out. Use stream: true for long requests.", "gateway_timeout");
      pieces = ["Streamed in time."];
    } else if (opts.meta && line === "overload") {
      failMidStream = n === 1;
      pieces = failMidStream ? ["Half"] : ["Calm again."];
    }
    else pieces = [`You said: ${line}`];

    const id = `chatcmpl-${log.length}`;
    if (!body.stream || opts.streaming === false) {
      for (const _ of pieces) if (wait) await sleep(wait);
      const said = pieces.filter((p) => p !== "DROP").join("");
      const text = thought ? `<thought>${thought}</thought>${said}` : said;
      return json(res, 200, { id, object: "chat.completion", model: body.model,
        choices: [{ index: 0, message: { role: "assistant", content: (opts.gemini && fin !== "stop") || refusal ? null : text,
                                         ...(reasoning ? { reasoning_content: reasoning } : opts.meta ? { reasoning_content: "" } : {}),
                                         ...(refusal ? { refusal } : {}) },
                    finish_reason: fin }],
        usage: { prompt_tokens: raw.length >> 2, completion_tokens: text.length >> 2,
                 ...(opts.grok ? { completion_tokens_details: { reasoning_tokens: reasoning.length >> 2 } } : {}) },
        ...(opts.grok ? { system_fingerprint: "fp_fake" } : {}) });
    }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const send = (d: unknown) => res.write(`data: ${JSON.stringify(d)}\n\n`);
    if (opts.gemini) {
      // No role-only opener; each chunk names the role; the last one finishes and counts.
      const chunk = (delta: any, finish: string | null, extra = {}) =>
        send({ id, object: "chat.completion.chunk", created: 0, model: body.model,
               choices: [{ index: 0, delta: { role: "assistant", ...delta }, finish_reason: finish }], ...extra });
      if (thought) chunk({ content: thought, extra_content: { google: { thought: true } } }, null);
      if (!pieces.length) chunk({}, fin, { usage: { prompt_tokens: raw.length >> 2, completion_tokens: 0 } });
      for (let i = 0; i < pieces.length; i++) {
        if (wait) await sleep(wait);
        const last = i === pieces.length - 1;
        chunk({ content: pieces[i] }, last ? fin : null, last ? { usage: { prompt_tokens: raw.length >> 2, completion_tokens: 3 } } : {});
      }
      if (opts.done !== false) res.write("data: [DONE]\n\n");
      return void res.end();
    }
    send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] });
    // Muse Spark's reasoning, redacted to "" for callers outside Meta.
    if (opts.meta) send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { reasoning_content: "" }, finish_reason: null }] });
    for (const r of reasoning ? [reasoning.slice(0, 4), reasoning.slice(4)] : []) {
      send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { reasoning_content: r }, finish_reason: null }] });
    }
    if (refusal) send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { refusal }, finish_reason: null }] });
    for (const p of pieces) {
      if (p === "DROP") {
        await sleep(150); // let the first pieces reach the client
        res.socket?.destroy(); // mid-stream, no finish
        return;
      }
      if (wait) await sleep(wait);
      send({ id, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: p }, finish_reason: null }] });
    }
    if (failMidStream) {
      res.write(`event: error\ndata: ${JSON.stringify({ error: { message: "The service is temporarily overloaded.", type: "server_error",
                                                                  param: null, code: "service_overloaded" } })}\n\n`);
      return void res.end();
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

/** Meta's error "type" by status. */
const META_TYPES: Record<number, string> = {
  400: "invalid_request_error", 401: "authentication_error", 402: "billing_error", 403: "permission_error",
  404: "invalid_request_error", 429: "rate_limit_error", 500: "server_error", 503: "server_error", 504: "server_error",
};

/** The words xAI puts in "code", by the status word Google's APIs use. */
const XAI_CODES: Record<string, string> = {
  INVALID_ARGUMENT: "Client specified an invalid argument",
  NOT_FOUND: "Some requested entity was not found",
  PERMISSION_DENIED: "The caller does not have permission to execute the specified operation",
  RESOURCE_EXHAUSTED: "Some resource has been exhausted",
};

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values: o } = parseArgs({ options: {
    port: { type: "string", default: "0" }, "no-streaming": { type: "boolean" }, "refuse-stream": { type: "boolean" },
    key: { type: "string" }, "no-done": { type: "boolean" }, gemini: { type: "boolean" }, grok: { type: "boolean" }, meta: { type: "boolean" },
  } });
  const f = await startFake({ port: Number(o.port), streaming: !o["no-streaming"], refuseStream: o["refuse-stream"],
                              key: o.key, done: !o["no-done"], gemini: o.gemini, grok: o.grok, meta: o.meta });
  console.log(`fake-model ${f.url}`);
}
